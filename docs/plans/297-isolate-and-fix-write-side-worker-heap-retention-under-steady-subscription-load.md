---
id: 297
slug: isolate-and-fix-write-side-worker-heap-retention-under-steady-subscription-load
title: "Isolate and fix write-side worker heap retention under steady subscription load"
kind: exec-plan
created_at: 2026-09-24T02:46:52Z
intention: "intention_01m38mx70deekbhtqefq54bpxx"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-24T02:46:52Z
  revisions:
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T05:09:54Z
      mode: "update"
      note: "Added real-adapter control and evidence requirements for upstream attribution"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-25T18:45:09Z
      mode: "implement"
      note: "Attempted Kenshou profiles and began dependency validation for the retention harness"
  reviews:
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T05:09:58Z
      verdict: "comments"
      note: "Reviewed source and sibling plan; real-adapter attribution gap updated, measurement validation remains advisory"
---

# Isolate and fix write-side worker heap retention under steady subscription load

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Keiro's process-manager and router workers are long-lived processes: they consume a
subscription to the event store and dispatch commands for every event, for hours or days.
Bug report [BUG-1](../bug-reports/1-write-side-workers-retain-heap-during-steady-soak.md)
records that in a five-minute steady workload driven by the external verification harness
Kenshou, both workers' live heap after major garbage collection grew without settling, at
fitted slopes of roughly 300 MB per hour for the process manager and 220 MB per hour for the
router. Nothing else grew: thread counts, file descriptors, native memory, and PostgreSQL
connections were flat. The report does not say which component retains the memory; the
workload combines keiro, the kiroku event store, the shibuya adapter that bridges them, and
Kenshou's own sampling wrappers.

After this plan, a keiro maintainer can run one command in this repository that drives the
process-manager and router workers over a real kiroku subscription for thousands of events
and prints, for each block of operations, the live heap after a forced major collection,
followed by a `bounded` or `retained` verdict. That command becomes part of `just verify`,
so a future regression fails the release gate. BUG-1 is closed with a status grounded in
that evidence: `fixed` if keiro owned the retention, `duplicate` of an upstream report if
kiroku or the adapter owned it, or `cannot-reproduce` with a written analysis if the
retention exists only inside the Kenshou harness. Either way, the report's reader learns
where the bytes went, not just that they grew.

This plan is one of two written for the two heap reports that Kenshou filed on 2026-09-24.
Its sibling,
[plan 298](298-isolate-and-fix-command-runner-heap-retention-over-long-snapshotted-histories.md),
covers the command runner over a long snapshotted history (BUG-2). The retained run data
strongly suggests one shared cause (see Context and Orientation), so this plan builds the
measurement harness both plans use, and plan 298 reuses it. If Milestone 2 here attributes
the growth to a layer that both reports exercise, plan 298 shrinks to confirming the fix.


## Progress


- [x] (2026-09-24) Link this plan from the BUG-1 report body and record the link in `docs/bug-reports/log.md`; the bundle validated under `--strict`.
- [x] (2026-09-25) Milestone 0: attempt Kenshou's closure-type profile for `keiro/pm-worker`; the run failed before a worker became ready and produced no event log.
- [x] (2026-09-25) Milestone 0: attempt the same profile for `keiro/router-worker`; it failed at the same point. Per the milestone's recovery rule, proceed to the in-repo harness without closure bands.
- [x] (2026-09-25) Milestone 1: add the `keiro-retention` test suite skeleton (`keiro/retention/Main.hs`, `Retention.Measure`) and prove the probe reports stable heap for the no-store baseline leg.
- [ ] Milestone 1: add `Retention.Fixture` (target aggregate, process manager, router, ack-coupled adapter) and the kiroku-only legs.
- [ ] Milestone 1: add an adapter-only leg using the released Shibuya–Kiroku adapter and compare it with the hand-built bridge before attributing worker growth.
- [ ] Milestone 1: add the process-manager, router, and projection legs; run all legs in report-only mode and record the per-leg tables.
- [ ] Milestone 2: decide attribution from the Milestone 0 and Milestone 1 evidence, record the decision, and re-status BUG-1 only when the evidence supports it.
- [ ] Milestone 3 (only if keiro owns the retention): profile the retained leg with `-hT` and the info-table build, fix the retaining code, and turn the leg into an asserting gate.
- [ ] Milestone 4: wire `cabal test keiro-retention` into `just haskell-test`, update `keiro/CHANGELOG.md`, close or re-status BUG-1 with `resolution`, validate the bundle, and distill an ADR.


## Surprises & Discoveries


- 2026-09-25: The two closure-type sessions, `.dev/profiles/profile-20260925T184247Z-closure-type` and `.dev/profiles/profile-20260925T184421Z-closure-type` in the Kenshou checkout, each exited 4 with `reason: "user error (worker did not become ready)"` and a zero-byte event log. There are no closure bands to attribute. The Kenshou checkout had unrelated pre-existing edits in `docs/layers/pgmq.md` and `kenshou-pgmq/src/Kenshou/Suite/Pgmq/Concurrency/Runner.hs`; this plan did not change them.

- 2026-09-25: The current Keiro tree is version 0.18.0.0 and requires `kiroku-store >=0.9 && <0.10` with `shibuya-core ^>=0.9.0.0`. Hackage's latest released `shibuya-kiroku-adapter` is 0.5.1.4, also tagged upstream, but it requires `shibuya-core >=0.10 && <0.11`. The cohort adapter 0.5.1.2 requires `kiroku-store ^>=0.8` and `shibuya-core >=0.9 && <0.10`; version 0.5.1.3 already requires Shibuya 0.10. No published adapter version has bounds for the current Keiro combination. The 0.8.0.1 to 0.8.0.2 subscription diff adds cancellation masking and test hooks; the 0.5.1.2 to 0.5.1.3 adapter diff changes the supervised handler contract and consumer-group acquisition, so the cohort comparison needs explicit version context.

- 2026-09-25: The first `keiro-retention` run passed its no-store baseline with six post-major samples, 5 B/op fitted slope, 0.01 MiB growth, and a flat 105,920-byte large-object reading. This confirms that the measurement code and its `-T` RTS setting work before adding store activity.


## Decision Log


- Decision: write two plans, one per bug report, with this plan owning the shared retention harness and plan 298 depending on it.
  Rationale: the user asked for two plans if the reports are unrelated. The retained run series (see Context and Orientation) show the same signature in both workloads, a few kilobytes of large-object heap retained per store-bearing operation, which makes one shared cause likely but unproven. Each report still needs its own reproduction and its own closure, and the two exercise different keiro surfaces (worker loops versus the command runner over snapshots). Two plans with an explicit dependency keep each closure honest while avoiding two harnesses.
  Date: 2026-09-24

- Decision: attribute before writing code. Milestone 0 runs Kenshou's own profiling recipe against the released cohort and reads the growing closure types before any keiro harness exists.
  Rationale: Kenshou already ships a per-worker-role heap-profiling recipe (`kenshou diagnose profile --worker ROLE`). A closure-type profile names whether the growth is thread stacks, byte arrays, thunks, or a constructor from `Kenshou.*`, `Kiroku.*`, or `Keiro.*`. That is the cheapest decisive evidence available and it needs no new code.
  Date: 2026-09-24

- Decision: the in-repo harness is a cabal test suite named `keiro-retention` with a report-only mode and small default sizes, not a benchmark and not part of `keiro-test`.
  Rationale: the growth the reports describe is 3 to 13 KB per operation, so 1,500 operations already exceed a 2 MiB growth floor by a wide margin, which keeps the suite short enough for `just verify`. A separate suite can carry the `-T` RTS option that `GHC.Stats` needs, and report-only mode lets the harness reproduce a defect before a gate exists.
  Date: 2026-09-24

- Decision: the Kenshou repository is read-only for this plan. This plan runs the `kenshou` command line and reads its retained run directories, but never edits Kenshou source, findings, or cohorts.
  Rationale: Kenshou is a separate project with its own plans and OKF bundles. Its finding record and its `knownDefect` references are updated by that repository once BUG-1 reaches a terminal status; this plan produces the hand-off text.
  Date: 2026-09-24

- Decision: closure vocabulary. `confirmed` when the in-repo harness reproduces retention in a keiro-owned leg; `fixed` with `fixedVersion: unreleased` once the fix lands on `master`; `duplicate` with `duplicateOf` pointing at the upstream report when a kiroku-only or adapter-only leg retains; `cannot-reproduce` with a `resolution` naming the evidence when every in-repo leg is flat and the Kenshou profile names only harness-owned closures.
  Rationale: these are the statuses the shared `coordination.bugReports` profile allows, and each terminal status must carry `resolution` under `--strict`.
  Date: 2026-09-24

- Decision: measure the real adapter as a separate leg and require matching growth and closure evidence before assigning an upstream owner.
  Rationale: the original fixture reproduced the adapter's ack protocol by hand, so it could not isolate Shibuya adapter retention. A growing kiroku leg also does not by itself prove that the worker's growing objects have the same source. Keep ambiguous cases open for a focused profile rather than closing BUG-1 as a duplicate.
  Date: 2026-09-24

- Decision: treat Milestone 0 as an attempted diagnostic and continue with Milestone 1 after both worker-role profiles failed before startup.
  Rationale: neither profile produced an event log or closure bands, and the plan explicitly allows the independent in-repo harness to proceed when the reduced soak cannot start. Attribution must therefore rely on the harness and any later focused profile; a failed profile is not evidence for any owner.
  Date: 2026-09-25


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


### The report and the bundle


`docs/bug-reports/` is an OKF bundle (OKF is the house Markdown-plus-frontmatter format that
the `okf` and `mori` tools validate and index). Its profile is the shared
`coordination.bugReports` profile pinned in `mori.dhall` and imported by
`mori/bug-reports-profile.dhall`. The profile fixes the `status` vocabulary: `reported`,
`confirmed`, `in-progress`, and the terminal values `fixed`, `wont-fix`, `duplicate`,
`not-a-bug`, and `cannot-reproduce`. `confirmed` means this repository reproduced the
defect, not that the reporter is sure. A terminal status must carry a `resolution` line, a
`fixed` status must carry `fixedVersion` (`unreleased` while the fix is only on `master`),
and `duplicate` must carry `duplicateOf`, which may be an external `mori://` URI. Every
change to the bundle is logged in `docs/bug-reports/log.md` and the bundle is validated by
`just bug-reports-validate` (part of `just verify`).

The report under work is
`docs/bug-reports/1-write-side-workers-retain-heap-during-steady-soak.md`, handle `BUG-1`,
`status: reported`, `severity: degraded`, `affectedVersion: 0.17.0.0`. Its intended canonical
cross-repository handle is `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-1`; the local
registry had not yet indexed the new bundle when this plan was written, so resolve it with
`mori path` after the next registry refresh rather than rewriting the reference.

The reporter is `mori://shinzui/keiro-runtime-kenshou`, the Keiro runtime verification
harness, checked out at `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`. Its finding
is `docs/findings/1-keiro-write-side-worker-heap-growth.md` in that repository, and the raw
run directory that produced the report is still on disk at
`runs/01a0d0e6-050d-7746-aaf2-bf0c11368618/` under that checkout. Both are read-only inputs
for this plan.


### What the workers are


A process manager in keiro is a saga: it consumes events from one aggregate's stream,
appends its own state event to a manager stream, and dispatches commands to target
aggregates, all with deterministic event identities so that a redelivery is recognised as a
duplicate rather than applied twice. A router is the stateless cousin: it consumes an event,
resolves a list of target commands (the resolver may run a query), and dispatches them. Both
have a "worker" form that drains a Shibuya adapter forever. Shibuya is the house queue
processing framework; an `Adapter es msg` (module `Shibuya.Adapter`) is a record with a
Streamly stream of `Ingested es msg` values, each carrying an `Envelope msg` and an
`AckHandle` whose `finalize` callback receives the worker's `AckDecision` (`AckOk`,
`AckRetry`, `AckDeadLetter`, `AckHalt`).

The worker loops live in:

- `keiro/src/Keiro/ProcessManager.hs`: `runProcessManagerWorkerWith` (line 965) folds the
  adapter's stream with `Streamly.fold Fold.drain (Streamly.mapM handleIngested source)`.
  Each message is decoded, passed to `runProcessManagerOnce` (line 533), and the result is
  turned into an `AckDecision` by `ackForResults` and `decideForFailures` (line 394). The
  handle is finalized exactly once per message.
- `keiro/src/Keiro/Router.hs`: `runRouterWorkerWith` (line 657) is the same shape over
  `runRouterOnce` (line 279) and `dispatchRouterCommands` (line 305).
- Both once-runners dispatch every target command through `dispatchDeduplicatedCommand`
  (`ProcessManager.hs` line 1150), which probes the target stream with
  `eventExistsInStream` for each deterministic candidate id before running
  `runCommandWithProjections`, and confirms benign duplicates afterwards.

The worker functions never allocate per-message state that outlives the message: metrics
are optional counters (`Nothing` in the failing runs, so every `record*` call in
`keiro/src/Keiro/Telemetry.hs` is a no-op), the tracer is `Nothing`, and the ack decision is
a small sum type. This is why reading the code alone does not locate the retention; the
harness below measures it.


### How the failing workload reaches the workers


Kenshou's fixture (`kenshou-keiro/src/Kenshou/Suite/Keiro/Fixture/Roles.hs` in the Kenshou
checkout) runs each worker as a separate child process. The process-manager role opens a
kiroku store with `Kiroku.Store.withStore`, builds an adapter with
`Shibuya.Adapter.Kiroku.kirokuAdapter` (package `shibuya-kiroku-adapter`, version 0.5.1.2 in
the failing cohort, source at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`),
wraps it in an ack interposer, and calls `runProcessManagerWorkerWith defaultWorkerOptions`.
The router role does the same with `runRouterWorkerWith` and a fan-out of four recipients.

The adapter is thin. It calls `Kiroku.Store.Subscription.Stream.subscriptionAckStream`
(kiroku-store 0.8.0.2 source at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`),
which starts a kiroku subscription whose handler pushes one `AckItem` per delivered event
into a bounded `TBQueue` and then blocks on a one-shot `TMVar` reply. The adapter converts
each `AckItem` into an `Ingested` whose `finalize` writes the reply. The kiroku worker
(`Kiroku/Store/Subscription/Worker.hs`, `processEvents` at line 712) delivers events one at a
time from fetched batches, checkpoints at the batch tail, and keeps no per-event structures.
So the ack-coupled path also has no obvious per-event retention on inspection.

Every Kenshou child process also runs `withRoleSampler`, a one-hertz thread that calls
`GHC.Stats.getRTSStats`, `GHC.Conc.listThreads`, and a native process sampler, and appends
one CSV line per sample. The command-writer children run keiro's `runCommand` in a loop with
no subscription. The projection-worker child runs a plain kiroku subscription (no shibuya
adapter, no keiro worker loop) whose handler calls `Keiro.Projection.applyAsyncProjection`
inside a kiroku transaction.


### What the retained run data shows


The run's per-child RTS series (`series/children/<role>/rts.csv`, one line per second) were
read for this plan. They show growth in every child, not only the two that received a
verdict; the writer and projection children were judged `insufficient-data` only because the
one-hertz sampler rarely lands on a major collection and the verdict needs post-major
points. The growth is almost entirely in the RTS counter `large_objects_bytes`, which counts
heap objects of about 3.3 KB and larger (byte arrays, large boxed arrays, and thread stack
chunks), and it is close to linear in time:

```text
child                 large_objects_bytes 58s -> 298s   post-major live bytes (points)   Haskell threads
keiro-pm-worker-0     4.63 MB -> 23.02 MB  (~77 KB/s)   527,680 -> 26,216,704 (11)        9 (flat)
keiro-router-worker-0 2.99 MB -> 15.80 MB  (~53 KB/s)   529,680 -> 21,746,240 (33)        9 (flat)
keiro-command-writer-0 3.62 MB -> 17.00 MB (~56 KB/s)   no verdict (0 post-major points)  8 (flat)
keiro-projection-worker-0 5.46 MB -> 27.76 MB (~93 KB/s) no verdict (0 post-major points) 9 (flat)
```

Dividing by the approximate operation rate of each child (about 31 account events per
second in total, one tenth of operations being transfers and one tenth bonuses) gives a
retained size of roughly 3 to 13 KB per store-bearing operation in every process. The
sibling report's main process shows the same shape: about 3.7 KB retained per command over
21,527 commands, again as large objects.

The consequences for this plan are:

1. The retaining layer is present in a process that runs only `runCommand` (no
   subscription, no adapter) and in a process that runs only a kiroku subscription plus
   `applyAsyncProjection` (no adapter, no keiro worker loop). A defect confined to the
   worker loops cannot explain the writer and projection children. The candidates that all
   four share are the kiroku store and its hasql/libpq connection layer, and Kenshou's
   role wrapper and sampler.
2. Keiro code is still on the path in three of the four children (the command runner, the
   dedupe probes, the projection apply), so keiro ownership is not excluded. The harness
   must therefore contain legs that run kiroku alone, legs that run keiro's worker over a
   kiroku subscription, and a no-store baseline, and compare them.
3. Because the retained objects are large, a closure-type heap profile will name them
   directly (`ARR_WORDS` for byte arrays, `STACK` for thread stacks, `THUNK` for deferred
   work, or a constructor). That is why Milestone 0 runs the profile before any code.

Related hasql facts checked for this plan: neither kiroku-store nor keiro builds SQL text
dynamically per call for preparable statements (the only concatenations are compile-time
constants in `keiro/src/Keiro/Outbox/Schema.hs`), so hasql's per-connection prepared
statement registry is bounded and is not a candidate.


### Existing tooling this plan reuses


- `keiro-test-support/src/Keiro/Test/Postgres.hs` provides `withMigratedSuite` (one cached
  ephemeral PostgreSQL server with a migrated template database) and
  `withFreshResourceStore`, which clones the template into a fresh database and hands the
  test a `KirokuStore` plus a `StoreRunner` that runs `Eff '[Store, Error StoreError,
  KirokuStoreResource, IOE]` actions. No external PostgreSQL is needed.
- `keiro/bench/Main.hs` defines a minimal keiki aggregate (`BenchCommand`, `BenchEvent`,
  `BenchState`, `benchEventStream`, `oneTransducer` at line 528) and validates it with
  `Keiro.EventStream.Validate.mkEventStreamOrThrow`. The retention fixture copies this
  pattern.
- `keiro/test/Main.hs` shows an in-memory adapter (`inMemoryAdapter`, line 18212) and a real
  ack-coupled subscription consumed by hand (`subscriptionAckStream store subConfig 4`, line
  730). The retention fixture combines the two for a kiroku bridge control. A separate
  adapter-only leg must call the actual `shibuya-kiroku-adapter` used by Kenshou.
- Kenshou's `kenshou diagnose profile` command (parser in
  `kenshou-cli/src/Kenshou/Cli/Diagnose.hs`) runs a scenario under RTS heap profiling.
  `--mode closure-type` passes `-hT` to the ordinary build; `--mode info-table` needs the
  info-table build from `just diagnose-build-info-table`; `--worker ROLE` profiles one child
  worker role instead of the main process by setting `KENSHOU_WORKER_GHCRTS_<ROLE>` for that
  child. Profiles are written under `--out` (default `.dev/profiles`).


### Architecture decision records


No local ADR covers heap-retention expectations for keiro workers or a memory gate in the
release process; this plan creates one in Milestone 4. Two local records constrain the
harness design:

- [ADR-25](../adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md)
  says a keiro background worker never lets one transient error end its loop or one bad
  item end its batch. The harness legs must not hide a dispatch failure behind a retention
  verdict: every leg checks that all operations succeeded before judging heap.
- [ADR-41](../adr/0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md)
  documents the deterministic identities and duplicate probes the worker performs per event;
  the fixture must use distinct correlation ids per source event so the probes run the same
  way they do in the Kenshou saga.

The cross-repository record that defines how Kenshou judges leaks is Kenshou's ADR-10,
"Judge heap leaks on live bytes after major collections", file
`docs/adr/0010-judge-heap-leaks-on-live-bytes-after-major-collections.md` in that checkout.
Its intended canonical handle is
`mori://shinzui/keiro-runtime-kenshou/okf/adrs/concepts/ADR-10`; the registry did not
resolve it at writing time, so verify with `mori path` before citing it in an ADR. The
harness follows the same rule: verdicts come from live bytes after forced major collections,
never from `max_live_bytes` (a high-water mark) or resident set size.


## Plan of Work


### Milestone 0: attribute with Kenshou's own profiling recipe


Scope: no keiro code changes. Run the reduced write-side soak under a closure-type heap
profile for the process-manager child, then for the router child, read the resulting event
logs, and record which closure types grow. If the growing band is a byte array or a thunk
band, also run the info-table variant for one role so the allocation site is named.

At the end of this milestone the plan's Surprises & Discoveries section holds, per role, the
top three growing closure types with their slopes, and the Decision Log holds a first
attribution hypothesis. Nothing else changes.

Work in the Kenshou checkout. Install the event-log tools once (`just diagnose-tools` puts
`eventlog2html` and `ghc-events` into `.dev/bin`). Kenshou provisions its own PostgreSQL
through ephemeral-pg, so no database setup is needed. Then:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou
nix develop -c just diagnose-tools
nix develop -c cabal run kenshou -- diagnose profile \
  keiro/command/soak/write-side-steady-state-reduced \
  --mode closure-type --interval-s 5 --worker keiro/pm-worker \
  --set soak.duration-minutes=5 --set command.rate-per-second=20 \
  --set command.accounts=16 --set router.fanout=4 \
  --set projection.prune-interval-seconds=60 \
  --dim pg.durability=durable --out .dev/profiles
```

Repeat with `--worker keiro/router-worker`. Each run prints the profile directory; render
the child's event log with `.dev/bin/eventlog2html <worker-eventlog> -o <html>` and open
the detailed view. Record the growing bands. The interpretation to apply:

- A growing `STACK` band with flat thread counts means one or more threads' stacks keep
  growing, which points at a non-tail-recursive loop; the info-table build's decoded stacks
  name it.
- A growing `ARR_WORDS` band means retained byte arrays (ByteString or Text payloads, hasql
  result buffers, encoded JSON). Run the info-table variant to get the allocation site:

```bash
nix develop -c just diagnose-build-info-table
BIN=$(nix develop -c cabal --project-file=cabal.diagnose-info-table.project \
  --builddir=dist-diagnose/info-table list-bin kenshou-cli:exe:kenshou)
nix develop -c "$BIN" diagnose profile \
  keiro/command/soak/write-side-steady-state-reduced \
  --mode info-table --interval-s 5 --worker keiro/pm-worker \
  --set soak.duration-minutes=5 --set command.rate-per-second=20 \
  --set command.accounts=16 --set router.fanout=4 \
  --set projection.prune-interval-seconds=60 \
  --dim pg.durability=durable --out .dev/profiles
```

- A constructor band names the owning module by its qualified name prefix (`Kenshou.`,
  `Kiroku.`, `Shibuya.`, `Keiro.`, `Hasql.`, `Database.PostgreSQL.LibPQ.`).

Acceptance: the two profile directories exist under `.dev/profiles` in the Kenshou checkout,
the rendered bands are summarised in this plan with the profile directory names, and the
Decision Log records the resulting hypothesis. If the profile run itself fails (for example
the reduced soak cannot start on this machine), record why and proceed to Milestone 1; the
in-repo harness does not depend on Milestone 0.


### Milestone 1: an in-repo retention harness with attribution legs


Scope: add a new cabal test suite `keiro-retention` to `keiro/keiro.cabal` whose modules
live under `keiro/retention/`. It provides one measurement primitive and a set of legs. A
leg is a named loop of N operations that shares nothing with the other legs; the harness
runs each leg in a fresh cloned database, samples the heap after forced major collections
between blocks of operations, prints a table, and judges the series.

At the end of this milestone, `cabal test keiro-retention` builds and runs every leg in
report-only mode, printing one table per leg. The tables are the reproduction evidence for
Milestone 2.

The measurement primitive (`keiro/retention/Retention/Measure.hs`). A sample is taken by
calling `System.Mem.performMajorGC`, then `GHC.Stats.getRTSStats`, and reading
`gcdetails_live_bytes` and `gcdetails_large_objects_bytes` from the `gc` field, plus the
length of `GHC.Conc.listThreads`. The suite's RTS options include `-T`, without which
`getRTSStats` throws; `Retention.Measure` checks `getRTSStatsEnabled` first and fails with a
clear message. A leg is driven by `measureLeg`, which runs `blocks` blocks of `blockSize`
operations, samples after each block, drops the first `warmupBlocks` samples, and computes
the least-squares slope of live bytes against operations (bytes per operation) and the
growth from the first kept sample to the last. The verdict is `Retained` when the slope
exceeds `slopeFloorBytesPerOp` and the growth exceeds `growthFloorBytes`; otherwise
`Bounded`. Defaults: 6 blocks of 250 operations (1,500 operations), 1 warm-up block, slope
floor 512 bytes per operation, growth floor 2 MiB. Environment variables override the
defaults: `KEIRO_RETENTION_OPERATIONS` (total operations, split evenly over the blocks),
`KEIRO_RETENTION_BLOCKS`, `KEIRO_RETENTION_LEGS` (comma-separated leg names to run), and
`KEIRO_RETENTION_REPORT_ONLY` (when set, tables are printed but no verdict fails the test).
Every leg prints its table to stdout in this form:

```text
leg=pm-worker operations=1500 blocks=6 block=250
block  ops   live_bytes   large_objects_bytes  threads
    1  250    2,113,400            1,204,224       12
    2  500    2,120,984            1,204,224       12
    ...
slope=  31 B/op  growth= 0.02 MiB  verdict=bounded
```

The fixture (`keiro/retention/Retention/Fixture.hs`). It defines, following
`keiro/bench/Main.hs`:

- A target aggregate `RetentionTarget` with commands `Credit Int` and events
  `Credited Int`, one control state, no registers, `snapshotPolicy = Never`, and
  `stateCodec = Nothing`, validated with `mkEventStreamOrThrow "retention-target"`. Target
  stream names are `retention-target-<k>` for `k` in `0 .. 15`, so sixteen targets share the
  load like the sixteen Kenshou accounts.
- A source event type `Signal { signalId :: Text, account :: Int }` stored in category
  `retention-source` (stream `retention-source-<signalId>`, one event per stream, so every
  source event has its own correlation id as Kenshou's transfers do) and a decoder
  `decodeSignal :: RecordedEvent -> Maybe (RecordedEvent, Signal)`.
- A process manager `retentionManager :: ProcessManager Signal ...` whose own aggregate is
  a one-state saga with command `Seen` and event `SeenRecorded`, `correlate = signalId`,
  `streamFor id = stream ("pm:retention-" <> id)`, and `handle signal = ProcessManagerAction
  { command = Seen, commands = [PMCommand (stream ("retention-target-" <> account)) (Credit 1)],
  timers = [] }`, with `targetProjections = const []`.
- A router `retentionRouter :: Router Signal ...` with `key = signalId` and
  `resolve signal = pure [PMCommand (targetFor k) (Credit 1) | k <- [0..3]]` (fan-out four).
- `ackAdapter :: KirokuStore -> SubscriptionConfig -> Natural -> IO (Adapter es RecordedEvent, IO ())`,
  which calls `subscriptionAckStream`, lifts the stream with `Streamly.morphInner liftIO`,
  and maps each `AckItem` to an `Ingested` whose envelope carries the event id as
  `messageId` and the attempt as `attempt`, and whose `finalize` translates the decision
  exactly as the shibuya adapter does: `AckOk` replies `Continue`, `AckRetry d` replies
  `Retry d`, `AckDeadLetter r` replies `DeadLetter`, and `AckHalt` runs the cancel action.
  The returned `IO ()` is the cancel action.
- `sampleOnAck :: Int -> (Int -> IO ()) -> IO () -> Adapter es msg -> Adapter es msg`, the
  interposer that counts finalized acks, runs the sampler callback after every `blockSize`
  acks, and runs the supplied cancel action after the last expected ack so the worker's stream
  ends and the worker function returns. For the real adapter, obtain that action from its
  `shutdown` field through the fixture's `StoreRunner`. Preserve the other adapter fields.
  Sampling inside `finalize` can retain the current handler frame and fetched batch;
  confirm growing tables with a profile and a post-worker-return sample before attribution.

The legs (`keiro/retention/Retention/Legs.hs`), each a function from the fixture handle
(`KirokuStore`, `StoreRunner`) to `IO ()` per operation, in this order:

1. `baseline-no-store`: allocate and discard a small list per operation, no database. This
   proves the probe itself is flat.
2. `kiroku-append-probe`: per operation, `appendToStream` one event to
   `retention-plain-<k mod 16>` with `AnyVersion` and then `eventExistsInStream` for that
   id. Kiroku and hasql only.
3. `kiroku-subscribe-ack`: before the loop, append `operations` source events; the loop is
   the consumer side of `subscriptionAckStream` replying `Continue` to every item, with the
   sampler driven every `blockSize` items. Kiroku's subscription worker and bridge only.
4. `shibuya-adapter-ack`: use `Shibuya.Adapter.Kiroku.kirokuAdapter` with
   `defaultKirokuAdapterConfig` targeting only `retention-source`; consume its source,
   finalize each item as `AckOk`, and call its `shutdown` at the operation limit. This
   measures the released adapter's envelope and ack conversion on the same kiroku
   subscription, without keiro dispatch. Match subscription configuration and fixture
   events across this leg and the worker legs.
5. `pm-worker`: pre-append the source events, then `runProcessManagerWorkerWith
   defaultWorkerOptions defaultRunCommandOptions retentionManager (sampleOnAck ...
   realAdapter) decodeSignal`, where `realAdapter` comes from `kirokuAdapter`. One
   operation is one delivered source event, which performs the
   manager append, the duplicate probes, and one target dispatch.
6. `router-worker`: as 5 with `runRouterWorkerWith` and fan-out four.
7. `projection-apply`: register a read model named `retention-activity` with
   `Keiro.ReadModel.Schema.registerReadModel` (as `keiro/test/CatalogSpec.hs` does for its
   fixtures), define an `AsyncProjection` whose `applyRecorded` does nothing and whose
   `idempotencyKey` is the event id (the same shape as `catalogAsyncProjection` at
   `keiro/test/CatalogSpec.hs` line 1246), and consume the source category with a plain
   kiroku `withSubscription` whose handler runs `applyAsyncProjection` in a transaction,
   sampling every `blockSize` events and stopping after the last.

Each leg asserts that all operations succeeded (no `Left` results, no dead letters, expected
number of target events) before its verdict, honouring ADR-25. The suite's `Main.hs` is an
hspec program under `withMigratedSuite`, one `it` per leg wrapped in
`withFreshResourceStore`, so each leg starts from an empty migrated database.

Acceptance: from the repository root,
`KEIRO_RETENTION_REPORT_ONLY=1 cabal test keiro-retention --test-show-details=direct` prints
seven tables and exits 0; the `baseline-no-store` table shows growth under 0.5 MiB. Tables for
the other legs are copied into Surprises & Discoveries.


### Milestone 2: attribute and re-status the report


Scope: decide, from Milestone 0 and the Milestone 1 tables, which layer retains. Record the
decision and move BUG-1 only when the worker evidence supports it. Ambiguous evidence calls
for another focused profile and leaves the report open. The outcomes are:

- `pm-worker` or `router-worker` retains while `kiroku-append-probe`,
  `kiroku-subscribe-ack`, and `shibuya-adapter-ack` are bounded: profile the retaining worker
  after confirming growth outside the finalize callback. If the growing allocations belong
  to keiro's dispatch path, set `status: confirmed` and continue with Milestone 3.
- A kiroku-only leg retains and its growth rate and closure profile match the retaining
  worker: the store layer is the likely owner. File a bug report in the kiroku repository's
  bug-report bundle
  (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, whose reports use the
  `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-N` shape) with the leg as the
  reproduction. Close BUG-1 as `duplicate` only after the worker evidence supports the
  same cause; otherwise leave it `reported` and profile the worker separately. The
  kiroku-side report and fix are outside this plan's repository and are recorded here only
  as a hand-off. Skip Milestone 3 only for the matching upstream case.
- `shibuya-adapter-ack` retains while the kiroku-only legs are bounded: profile that leg
  and the worker, then file the upstream report against the adapter only if the growing
  closures match. Keep BUG-1 open if the worker has additional growth.
- Every leg is bounded at the default size and at `KEIRO_RETENTION_OPERATIONS=20000` for
  the two worker legs, and the Milestone 0 bands name only `Kenshou.*` closures or thread
  stacks of Kenshou threads: close BUG-1 as `cannot-reproduce` with a `resolution` that
  cites the leg tables and the profile bands, and write the hand-off text for Kenshou (the
  finding record and the scenario's `knownDefect` are theirs to update). Skip Milestone 3.

When attribution is supported, update `docs/bug-reports/1-write-side-workers-retain-heap-during-steady-soak.md`:
set `status`, add `resolution` when terminal, add `duplicateOf` when duplicate, set
`generated.by` to the process actually making the edit and `generated.at` to the current
UTC time, and
append a short "Attribution" paragraph to the body naming the legs and their verdicts. Then:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
okf log add docs/bug-reports --kind Update -m "BUG-1 <new status>: <one-line reason>"
just bug-reports-validate
```

Acceptance: the report's frontmatter validates under `--strict`, the log has the entry, and
the Decision Log here records the attribution with the evidence it rests on.


### Milestone 3: fix a keiro-owned retention and make the leg a gate


Scope: only when Milestone 2 chose `confirmed`. Locate the retaining closures, remove the
retention, and turn the retaining leg into an asserting gate.

First profile the retaining leg alone with the ordinary build's closure-type profile:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
KEIRO_RETENTION_LEGS=pm-worker KEIRO_RETENTION_OPERATIONS=6000 KEIRO_RETENTION_REPORT_ONLY=1 \
  cabal test keiro-retention --test-show-details=direct \
  --test-options='+RTS -hT -i0.5 -l-agu -RTS'
```

This writes `keiro-retention.eventlog` in the test's working directory; render it with
`eventlog2html` (install into `.dev/bin` the same way Kenshou does:
`cabal install --ignore-project --installdir=.dev/bin --install-method=copy eventlog2html-0.12.0`).
If the band is `ARR_WORDS` or `THUNK`, add a project file `cabal.retention-info-table.project`
at the repository root containing `import: cabal.project` and a `package *` stanza with
`ghc-options: -finfo-table-map -fdistinct-constructor-tables`, build the suite with
`cabal --project-file=cabal.retention-info-table.project --builddir=dist-retention test
keiro-retention --test-options='+RTS -hi -i0.5 -l-agu -RTS'`, and read the allocation sites
in the rendered detailed view.

Then fix the retention in the module the profile names. The fix must keep the worker
contract unchanged: the same ack decisions for the same outcomes, exactly one finalize per
message, and no change to deterministic ids. Add a focused hspec example in `keiro-test`
only if the fix changes observable behaviour; otherwise the retention leg is the regression
test. Remove `KEIRO_RETENTION_REPORT_ONLY` from the leg's default behaviour so the leg
asserts `Bounded`.

Acceptance: `cabal test keiro-retention` passes with the retaining leg asserting; the leg's
table before and after the fix is recorded in Surprises & Discoveries; `just haskell-verify`
passes.


### Milestone 4: gate, changelog, report closure, ADR


Scope: make the harness part of the release gate and finish the paperwork.

Add `cabal test keiro-retention` to the `haskell-test` recipe in `justfile` after
`cabal test keiro-test`. Add an entry under `## [Unreleased]` in `keiro/CHANGELOG.md`: under
"Other Changes" for the new suite, and under "Bug Fixes" (create the heading if absent) for a
keiro-owned fix, naming BUG-1. When the fix is keiro-owned, set the report to `status: fixed`
with `fixedVersion: unreleased` and a `resolution` line, log it, and validate. Write the
Kenshou hand-off paragraph in this plan's Outcomes section: the scenario id, the knobs, the
expected verdict change, and the cohort note that Kenshou's `cohort/head.project` must point
at the fixing commit before the reduced soak can re-verify it.

Distill an ADR in `docs/adr/` following `ADR.md` in the exec-plan skill (allocate the next
handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`, add a `log.md` entry,
and run `just adr-validate`). The record states that keiro judges worker and command heap
retention on live bytes after forced major collections per block of operations in an in-repo
suite that runs in `just verify`, with the growth and slope floors chosen here, and cites
Kenshou's ADR-10 by its canonical handle once `mori path` resolves it.

Acceptance: `just verify` passes end to end; the bug-report bundle and the ADR bundle
validate; the CHANGELOG entry exists; the plan's Outcomes & Retrospective is written.


## Concrete Steps


All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` inside the
project shell (`nix develop`), except the Milestone 0 commands, which run from the Kenshou
checkout as shown above.

The tracking link in the report was added when this plan was created (see Progress); the
bundle validated with `just bug-reports-validate` printing `OK: 2 concepts`. Start at
Milestone 0.

Build and run the harness (Milestone 1):

```bash
cabal build keiro:test:keiro-retention
KEIRO_RETENTION_REPORT_ONLY=1 cabal test keiro-retention --test-show-details=direct
```

Expected transcript shape (numbers will differ):

```text
Retention legs
  baseline-no-store
leg=baseline-no-store operations=1500 blocks=6 block=250
block  ops   live_bytes   large_objects_bytes  threads
    1  250      812,344              212,992        7
...
slope=   0 B/op  growth= 0.00 MiB  verdict=bounded
  kiroku-append-probe
...
6 examples, 0 failures
```

Scale a leg for investigation:

```bash
KEIRO_RETENTION_LEGS=pm-worker,router-worker KEIRO_RETENTION_OPERATIONS=20000 \
  KEIRO_RETENTION_REPORT_ONLY=1 cabal test keiro-retention --test-show-details=direct
```

Commit after each milestone with the two trailers:

```text
ExecPlan: docs/plans/297-isolate-and-fix-write-side-worker-heap-retention-under-steady-subscription-load.md
Intention: intention_01m38mx70deekbhtqefq54bpxx
```


## Validation and Acceptance


The plan is complete when all of the following hold:

1. `cabal test keiro-retention` runs the seven legs from an empty ephemeral database and
   prints one table per leg. With the default sizes the run finishes in well under five
   minutes on a laptop; if it does not, reduce `blockSize` before reducing `blocks`, because
   the verdict needs at least five kept samples.
2. `baseline-no-store`, `kiroku-append-probe`, `kiroku-subscribe-ack`, and
   `shibuya-adapter-ack` are `bounded`, or the plan's Decision Log records matching upstream
   attribution and BUG-1 is `duplicate` with a
   resolvable `duplicateOf`.
3. `pm-worker` and `router-worker` are `bounded` at the default size and at 20,000
   operations, either because they always were (then BUG-1 is `cannot-reproduce` with the
   profile evidence) or because Milestone 3 fixed them (then BUG-1 is `fixed`).
4. `just verify` passes, which includes the new suite, the bug-report bundle validation, and
   the ADR bundle validation.
5. The report body names the legs and verdicts so a reader can rerun the attribution.


## Idempotence and Recovery


Every leg runs in a freshly cloned database, so legs and the whole suite can be rerun at any
time. Profiles and event logs are written under `.dev/` in either repository and are not
committed; copy only the summarised bands into this plan. If a Kenshou profile run leaves
child processes behind after a failure, `pkill -f 'kenshou worker'` in that checkout is
safe. If the ephemeral PostgreSQL root under `/tmp/ephpg-keiro-<uid>` accumulates stale
clusters, the next `withMigratedSuite` start sweeps them. Bug-report edits are plain text;
a wrong status can be corrected with another `okf log add` entry rather than by rewriting
history. The test-suite stanza and justfile change are additive and can be reverted with a
single commit if the gate proves too slow, in which case leave the suite runnable on demand
and record why in the Decision Log.


## Interfaces and Dependencies


New cabal stanza in `keiro/keiro.cabal`:

```text
test-suite keiro-retention
  import: warnings, shared
  type: exitcode-stdio-1.0
  hs-source-dirs: retention
  main-is: Main.hs
  other-modules:
    Retention.Fixture
    Retention.Legs
    Retention.Measure
  ghc-options:
    -threaded
    -rtsopts
    "-with-rtsopts=-N -T"
  build-depends:
    aeson, base, containers, deepseq, effectful, effectful-core, hasql, hasql-transaction,
    hspec, keiki, keiki-codec-json, keiro, keiro-core, keiro-test-support, kiroku-store,
    shibuya-core, shibuya-kiroku-adapter, stm, streamly-core, text, time, uuid, vector
```

Use the same version bounds the `keiro-test` stanza uses for packages already present
there. For `shibuya-kiroku-adapter`, verify the current release in the authoritative
package registry and its upstream tag, then choose a bound covering that release and
record which adapter version the retention suite actually used.

`Retention.Measure` must export:

```haskell
data HeapSample = HeapSample
  { operations :: !Int, liveBytes :: !Word64, largeObjectBytes :: !Word64, threads :: !Int }

data Verdict = Bounded | Retained deriving stock (Eq, Show)

data GateConfig = GateConfig
  { blocks :: !Int, blockSize :: !Int, warmupBlocks :: !Int
  , slopeFloorBytesPerOp :: !Double, growthFloorBytes :: !Word64, reportOnly :: !Bool }

gateConfigFromEnvironment :: IO GateConfig
sampleHeap :: Int -> IO HeapSample
judge :: GateConfig -> [HeapSample] -> (Verdict, Double, Word64)
measureLeg :: GateConfig -> Text -> (Int -> IO ()) -> IO (Verdict, [HeapSample])
measureLegWithSampler :: GateConfig -> Text -> ((Int -> IO ()) -> IO ()) -> IO (Verdict, [HeapSample])
renderTable :: Text -> GateConfig -> [HeapSample] -> (Verdict, Double, Word64) -> Text
```

`measureLeg` drives a per-operation action itself; `measureLegWithSampler` hands a sampler
callback to a leg that controls its own loop (the worker legs, which sample from the ack
interposer). Both print the table and return the verdict and samples.

`Retention.Fixture` must export the aggregate types, `retentionTargetStream`,
`retentionManager`, `retentionRouter`, `signalStreamName`, `appendSignals :: StoreRunner ->
Int -> IO ()`, `decodeSignal`, `ackAdapter`, and `sampleOnAck` with the signatures given in
Milestone 1.

`Retention.Legs` must export one `Leg` value per leg, where
`data Leg = Leg { legName :: Text, run :: GateConfig -> (KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample]) }`,
and `allLegs :: [Leg]` in the order listed in Milestone 1.

Dependencies and why: `keiro-test-support` for the migrated ephemeral database;
`kiroku-store` for `subscriptionAckStream`, `withSubscription`, `appendToStream`, and
`eventExistsInStream`; `shibuya-core` for `Adapter`, `Ingested`, `Envelope`, `AckHandle`,
and `AckDecision`; `shibuya-kiroku-adapter` for the real `kirokuAdapter`;
`streamly-core` for `Stream.morphInner` and `Stream.mapM`; `keiki` and
`keiki-codec-json` for the fixture transducer and codecs; `hspec` for the runner. Resolved
versions in this workspace when the plan was written: kiroku-store 0.8.0.2, shibuya-core
0.9.0.3, hasql 1.10.3.7, hasql-pool 1.4.2.3, streamly-core 0.3.1, effectful 2.6.1.0, GHC
9.12.4. The failing Kenshou cohort used kiroku-store 0.8.0.1, shibuya-kiroku-adapter
0.5.1.2, and keiro 0.17.0.0. This plan read the workspace trees, not the released tags; the
versions differ only by patch releases, but before treating the harness as equivalent to
the failing cohort, diff the tags in the kiroku checkout
(`git diff kiroku-store-v0.8.0.1 kiroku-store-v0.8.0.2 -- kiroku-store/src/Kiroku/Store/Subscription`
and the same for `shibuya-kiroku-adapter-v0.5.1.2..v0.5.1.3`) and record the result in
Surprises & Discoveries.


## Revision Notes


- 2026-09-24: Reviewed this plan with plan 298 and added a real-adapter control. Attribution
  now requires matching worker evidence before closing BUG-1 as an upstream duplicate;
  samples inside ack finalization are explicitly treated as provisional. This addresses
  the gap between the hand-built adapter and Kenshou's actual worker path.
