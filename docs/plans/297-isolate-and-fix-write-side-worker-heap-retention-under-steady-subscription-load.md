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
- [x] (2026-09-25) Milestone 0: attempt the same profile for `keiro/router-worker`; it failed at the same point. Per the milestone's recovery rule, proceed to the in-repo harness without closure bands while investigating profile startup.
- [x] (2026-09-25) Milestone 1: add the `keiro-retention` test suite skeleton (`keiro/retention/Main.hs`, `Retention.Measure`) and prove the probe reports stable heap for the no-store baseline leg.
- [x] (2026-09-25) Milestone 1: add `Retention.Fixture` (target aggregate, process manager, router, ack-coupled adapter) and the kiroku-only legs.
- [x] (2026-09-25) Milestone 1: add an adapter-only leg using released Shibuya–Kiroku adapter 0.5.1.2 and compare it with the hand-built bridge.
- [x] (2026-09-25) Milestone 1: add the process-manager, router, and projection legs; run the original seven legs in report-only mode at 60 and 1,500 operations and record the per-leg tables.
- [x] (2026-09-25) Add a distinct hand-built ack bridge control, so the raw subscription, bridge, and released adapter can be compared without conflating their costs.
- [x] (2026-09-25) Add append-only, transactional-append, and probe-only controls after the combined Kiroku control showed large-object growth during a 20,000-operation burst.
- [x] (2026-09-25) Milestone 2: run the process-manager leg at 20,000 operations; its earlier positive slope settled.
- [x] (2026-09-25) Run the final eight-leg asserting default suite after the bridge control and router policy change; all eight passed in 93.9 seconds.
- [x] (2026-09-25) Run the expanded eleven-leg asserting default suite after adding append-only, transactional-append, and probe-only controls; all eleven passed in 112.2 seconds.
- [x] (2026-09-25) Milestone 2: profile both worker roles on the exact released cohort and record their major-GC and closure-type series.
- [x] (2026-09-25) Milestone 2: complete info-table profiles for both released-cohort worker roles, pace the direct append control, and verify a strict Kiroku publisher update against the 20,000-append control.
- [x] (2026-09-25) Milestone 2: attribute the shared worker growth to Kiroku's lazy publisher position update, file `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3`, and close Keiro BUG-1 as its duplicate.
- [x] (2026-09-25) Milestone 3: skipped because both worker profiles name the Kiroku-owned publisher site and the isolated strict Kiroku update removes the distinctive large-object growth; no Keiro worker code is implicated.
- [x] (2026-09-25) Milestone 4: wire `cabal test keiro-retention` into `just haskell-test`, update `keiro/CHANGELOG.md`, close BUG-1 as an upstream duplicate with a resolution, validate both local bundles, record ADR-48, and pass `just verify` end to end.


## Surprises & Discoveries


- 2026-09-25: The two closure-type sessions, `.dev/profiles/profile-20260925T184247Z-closure-type` and `.dev/profiles/profile-20260925T184421Z-closure-type` in the Kenshou checkout, each exited 4 with `reason: "user error (worker did not become ready)"` and a zero-byte event log. There are no closure bands to attribute. The Kenshou checkout had unrelated pre-existing edits in `docs/layers/pgmq.md` and `kenshou-pgmq/src/Kenshou/Suite/Pgmq/Concurrency/Runner.hs`; this plan did not change them.

- 2026-09-25: The generated worker stderr in the first failed profile says `initEventLogFileWriter: can't open .dev/profiles/.../worker-keiro/pm-worker-93016.eventlog: No such file or directory`. Kenshou's `reexecWithWorkerRts` uses the slash-bearing worker role directly in the event-log filename, so it needs a `worker-keiro` directory inside each generated profile session. The failed profile is a path-construction issue, not evidence about worker heap. A temporary directory in the generated session should allow a rerun without changing Kenshou source.

- 2026-09-25: The current Keiro tree is version 0.18.0.0 and requires `kiroku-store >=0.9 && <0.10` with `shibuya-core ^>=0.9.0.0`. Hackage's latest released `shibuya-kiroku-adapter` is 0.5.1.4, also tagged upstream, but it requires `shibuya-core >=0.10 && <0.11`. The cohort adapter 0.5.1.2 requires `kiroku-store ^>=0.8` and `shibuya-core >=0.9 && <0.10`; version 0.5.1.3 already requires Shibuya 0.10. No published adapter version has bounds for the current Keiro combination. The 0.8.0.1 to 0.8.0.2 subscription diff adds cancellation masking and test hooks; the 0.5.1.2 to 0.5.1.3 adapter diff changes the supervised handler contract and consumer-group acquisition, so the cohort comparison needs explicit version context.

- 2026-09-25: The first `keiro-retention` run passed its no-store baseline with six post-major samples, 5 B/op fitted slope, 0.01 MiB growth, and a flat 105,920-byte large-object reading. This confirms that the measurement code and its `-T` RTS setting work before adding store activity.

- 2026-09-25: Kiroku defines a stream's category as the prefix before its first hyphen (`Kiroku.Store.Types.categoryName`). The proposed `retention-source-*` and `retention-target-*` names would both have category `retention`, causing the source subscription to consume target events as well. The fixture therefore uses `retentionsource-*` and `retentiontarget-*`, with a `Category "retentionsource"` subscription.

- 2026-09-25: All seven legs passed in report-only mode at 60 and at 1,500 operations. The default-sized run took 87.8 seconds with the released 0.5.1.2 adapter, Kiroku 0.9.0.0, and Keiro 0.18.0.0. The six post-major live-byte samples for each leg, followed by fitted slope, kept-sample growth, and verdict, were:

```text
leg                       live bytes at blocks 1..6                                       slope B/op   growth MiB  verdict
baseline-no-store         314016 301528 301976 303392 304832 306248                           5           0.00      bounded
kiroku-append-probe       759976 1163544 1571272 2003152 2373344 2767600                  1604           1.53      bounded
kiroku-subscribe-ack      1832880 1827048 1829336 1830496 1833360 1835096                   8           0.01      bounded
shibuya-adapter-ack       2331560 2313776 2316648 2318616 2320600 2321736                   8           0.01      bounded
pm-worker                 3149912 3529752 3756848 4145112 4331912 4586280                  1075           1.01      bounded
router-worker             5859280 4185208 3107888 2019488 1606368 1646200                 -2632           0.00      bounded
projection-apply          1762040 1757960 1802360 1817840 1861256 1877208                  119           0.11      bounded
```

  The no-store large-object reading was flat at 151,200 bytes and its thread count stayed 28. The append/probe large-object reading rose from 413,440 to 1,735,248 bytes with threads flat at 28. The process-manager large-object reading varied from 411,184 to 509,272 bytes with threads flat at 28; its live-byte slope therefore does not yet match the append/probe's large-object signature. The router's live heap fell as the run progressed. The raw subscription and real adapter matched each other closely. All operations succeeded and the worker target event counts matched the expected counts. Sampling inside callbacks remains provisional; post-return live-byte readings were 1,694,080 (raw subscription), 2,164,504 (adapter), 4,543,152 (manager), 1,594,864 (router), and 1,638,512 (projection).

- 2026-09-25: At 20,000 operations over eight blocks of 2,500, the process-manager live-byte samples were 3,055,344; 2,474,120; 2,587,128; 2,437,312; 2,124,648; 1,925,352; 1,773,168; and 1,526,536. The fitted slope was -71 B/op with zero kept-sample growth and flat 23-thread count. The post-return live heap was 1,466,296 bytes. The positive 1,500-operation slope was transient warm-up, not sustained worker retention in this fixture.

- 2026-09-25: The unsnapshotted four-target router run was interrupted after about ten minutes before completing 20,000 operations. Each dispatch repeatedly replayed one of four growing target streams, so command history cost dominated the worker measurement. The default 1,500-operation router leg remains unsnapshotted. For longer runs, the fixture switches target streams to `Every 100` snapshots and reports that policy. That longer result tests worker retention under sustained subscription load, but cannot substitute for a profile of the original unsnapshotted Kenshou workload when assigning BUG-1 ownership.

- 2026-09-25: With `Every 100` target snapshots, the router completed 20,000 operations in 162.8 seconds. Its eight live-byte samples were 7,061,896; 7,281,208; 7,471,672; 7,905,288; 7,983,824; 8,442,840; 8,427,312; and 8,766,136. The fitted slope was 99 B/op and kept-sample growth 1.42 MiB, below both retention floors. The post-return live heap was 7,198,304 bytes. Threads increased from 22 to 25 during the run, so this result remains bounded by the test's live-byte criterion but merits comparison with the original Kenshou profile before report closure.

- 2026-09-25: The final eight-leg asserting run at 1,500 operations passed in 93.9 seconds. The new hand-built bridge had a fitted slope of 8 B/op and 0.01 MiB growth, matching the raw Kiroku and released adapter controls. Baseline was 6 B/op and 0.01 MiB; append/probe 1,684 B/op and 1.61 MiB; raw ack 8 B/op and 0.01 MiB; released adapter 8 B/op and 0.01 MiB; process manager 1,007 B/op and 0.94 MiB; unsnapshotted router -2,932 B/op with zero growth; projection 119 B/op and 0.11 MiB. All verdicts were `bounded` under the configured two-floor gate, and target event assertions passed. The positive append/probe short-run slope still needs a longer control run.

- 2026-09-25: A 20,000-operation append/probe control completed in about five seconds and grew 21.93 MiB across kept samples at 1,538 B/op, with large-object bytes reaching 19.79 MiB. An immediate post-return sample stayed at 30.89 MiB live and 19.79 MiB large objects. Holding one `StoreRunner` effect invocation across the whole loop did not change this signature: the control still reached 30.71 MiB live and 19.62 MiB large objects, and the asserting long-run leg failed. Its `-hT` profile, however, named growing `GHC.Internal.Event.PSQ.Bin` (2.71 MiB), list cells (2.58 MiB), `TVAR` (2.54 MiB), `GHC.Internal.Conc.Sync.TVar` (1.27 MiB), and `FUN_1_0` (1.27 MiB) across eight samples. These are event-manager and STM-shaped structures, not Kiroku event payload constructors; the five-second burst may be keeping pending timeouts alive.

- 2026-09-25: The 60-second settling measurement reduced combined append/probe live bytes from 29.84 MiB to 20.99 MiB, but large-object bytes remained at 18.74 MiB. The append-only leg retained 16.92 MiB across kept samples at 1,184 B/op, with large objects rising to 15.03 MiB. The probe-only leg's large-object bytes stayed flat at 15.19 MiB after its preloading append phase; its probe slope was 112 B/op with 1.60 MiB growth, below the gate floors. The transactional-append leg also retained 16.47 MiB at 1,152 B/op with large objects reaching 14.67 MiB. Thus both append paths grow during a roughly five-second burst, while existence probes do not add large objects. The process-manager path performs 20,000 events over several minutes and settles, so burst results cannot be directly attributed to its steady-load behavior.

- 2026-09-25: Supplying a `worker-keiro` directory inside a generated Kenshou profile session let the process-manager profile run. The child event log had 22 closure-type samples over 274.6 seconds. Its RTS major-GC live bytes grew to about 25.6 MiB and large-object bytes to 22.9 MiB, reproducing the original signal, but the closure census totaled only 0.89 to 2.19 MiB. Its largest visible growing bands were ByteString `BS` wrappers (+318,720 bytes), generic `THUNK_2_0` (+318,688), `THUNK_1_0` (+239,040), `ARR_WORDS` (+224,976), and `PlainPtr` (+159,360). Those bands do not account for the much larger RTS large-object growth, so closure type alone cannot assign ownership. The shared Kenshou checkout's active Cabal project had also moved to its head cohort, which pins an unreleased Shibuya core commit; the profile's `dist-newstyle/cache/plan.json` confirmed that source. A detached worktree from the tracked Kenshou HEAD, with `cohort/active.project` importing `released.project`, is being built for exact released-cohort profiles without changing the shared checkout.

- 2026-09-25: The detached worktree's dependency plan confirmed the original released versions: Keiro 0.17.0.0, Kiroku Store 0.8.0.1, Shibuya core 0.9.0.3, and Shibuya–Kiroku adapter 0.5.1.2, all registry tarballs. Its five-minute process-manager profile again failed the scenario leak verdict but produced a usable child event log, with 21 closure-type samples over 275 seconds. RTS major-GC live bytes rose from 446,368 to 24,708,088 and large-object bytes from 308,392 to 23,138,848. The closure census totaled 930,800 to 2,132,744 bytes; top visible growth was `THUNK_2_0` (+311,136), ByteString `BS` (+311,136), `THUNK_1_0` (+233,352), `ARR_WORDS` (+203,896), and `PlainPtr` (+155,568). This reproduces the same signature on the exact released cohort, but the closure-type census still does not account for the large-object bytes.

- 2026-09-25: The exact released-cohort router profile also failed the scenario leak verdict. Its child event log had 22 closure-type samples over 272.8 seconds. RTS major-GC live bytes rose from 435,664 to 22,366,576 and large-object bytes from 309,440 to 16,264,208. The closure census totaled 718,960 to 1,931,648 bytes. Its largest growing bands were `THUNK_2_0` (+315,168), ByteString `BS` (+315,168), `THUNK_1_0` (+236,352), `ARR_WORDS` (+163,904), and `PlainPtr` (+157,584). The common band shapes across two different workers point to a shared path, but neither closure-type census accounts for the larger RTS large-object growth. An info-table build is underway to identify the generic allocation sites.

- 2026-09-25: Pacing the isolated `kiroku-append-only` leg at 20 operations per second for 3,000 operations (about 160 seconds) still produced a positive 942 B/op fitted live-heap slope. The six post-major live-byte samples were 983,424; 1,430,952; 1,859,416; 2,285,360; 2,814,000; and 3,308,024, with large-object bytes rising from 679,968 to 2,719,592. The two-floor verdict was `bounded` because kept-sample growth was 1.79 MiB, just below the 2 MiB floor. This control shows rate alone does not flatten append-path growth over this interval; a longer run or an ownership profile is needed before classifying it as lasting retention.

- 2026-09-25: The expanded eleven-leg suite passed in asserting mode at the default 1,500 operations in 112.2 seconds. The unsnapshotted router's slope was -2,382 B/op with zero kept-sample growth; process manager 721 B/op and 0.59 MiB; projection 119 B/op and 0.11 MiB. All eleven verdicts were `bounded`, including the new direct append, transactional append, and probe-only controls. The long burst behavior remains a separate diagnostic rather than a default-size failure.

- 2026-09-25: A standalone threaded GHC 9.12.4 control registered 3,000 30-second STM delays, sampling after each 500 registrations with forced major GC. Live bytes reached only 378,568 and large-object bytes 28,688; after 60 seconds idle they fell to 75,920 and 61,456 respectively. Repeated `registerDelay` alone does not reproduce the multi-megabyte large-object signature, despite the Event.PSQ and TVar bands in the closure profile. The timer hypothesis is therefore insufficient without another retaining reference or workload component.

- 2026-09-25: The exact released-cohort process-manager info-table profile in the detached Kenshou worktree, `.dev/profiles/profile-20260925T200534Z-info-table`, again failed the scenario leak verdict and produced a 150 MiB child event log. Its 21 info-table samples span 268.3 seconds; the sampled closure census grew from 919,912 to 2,162,536 bytes. The largest mapped growth sites were a Kiroku publisher thunk at `Kiroku.Store.Subscription.EventPublisher` line 251 (+307,488 bytes) and a Hasql value-decoder closure at `Hasql.Codecs.Decoders.Value` lines 97–98 (+230,616 bytes). A boot-library closure with no info-table map grew by the same 307,488 bytes as the publisher thunk. The worker RTS series rose from 468,400 to 21,344,576 post-major live bytes and from 347,336 to 19,930,464 large-object bytes while its thread count stayed 11 to 10. The released Kiroku 0.8.0.1 and current 0.9.0.0 source both use `writeTVar posVar (GlobalPosition (max cur tailPos))` at that publisher site when no queue subscriber is registered. Because `GlobalPosition` is a non-strict newtype over `Int64`, the TVar can hold a chain of unevaluated `max` calls and their Hasql results. Category subscriptions do not register publisher queue subscribers, so this path remains active during both worker roles.

- 2026-09-25: A detached Kiroku 0.9.0.0 worktree changed only the publisher's empty-subscriber update to force `nextPos = max cur tailPos` before `writeTVar`. The same Keiro `kiroku-append-only` 20,000-operation burst then measured 332 B/op, 4.75 MiB kept-sample live growth, and large-object bytes flat at about 0.30 MiB across blocks 2–8; the post-return large-object reading was 309,368 bytes. The released build measured 1,184 B/op, 16.92 MiB live growth, and 15.03 MiB large objects. The strict update removes the distinctive large-object accumulation without changing Keiro code. The patch is an isolated experiment; no Kiroku release includes it yet.

- 2026-09-25: The exact released-cohort router info-table profile, `.dev/profiles/profile-20260925T201406Z-info-table`, independently found the same Kiroku publisher line 251 (+323,392 bytes) and Hasql decoder lines 97–98 (+242,544 bytes) among 22 samples spanning 279.3 seconds. Its closure census rose from 722,800 to 1,965,632 bytes; the worker RTS series rose from 469,296 to 18,059,016 post-major live bytes and from 343,592 to 16,616,720 large-object bytes, with threads 11 to 10. Both worker roles therefore point to the same Kiroku-owned retaining path. The in-repo worker legs were bounded because they consume source events pre-appended before sampling, while Kenshou supplies them live; that fixture difference explains why the Keiro gate did not reproduce the combined worker trend.

- 2026-09-25: The new upstream BUG-3 report, bundle index, and log were committed in `mori://shinzui/kiroku` and passed `okf validate` with profile and log enforcement. Kiroku's `--strict` bundle check still reports missing review metadata in its two pre-existing bug reports; BUG-3 itself has review metadata and is not among those diagnostics. Keiro's BUG-1 bundle passes its own strict validation. `mori path` cannot yet resolve BUG-3's intended canonical artifact URI because the local registry or artifact coverage has not incorporated the new report.

- 2026-09-25: The two exact released-cohort closure-type sessions and the two info-table sessions were copied from the detached profiling worktree to the main Kenshou checkout's `.dev/profiles/` directory. Their child event logs and run reports are retained there under the profile directory names above; no tracked Kenshou source or cohort file was changed.


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

- Decision: use the cohort's released adapter 0.5.1.2 for the real-adapter legs and narrowly relax its stale `kiroku-store` upper bound in `cabal.project`.
  Rationale: Hackage and upstream tags agree that 0.5.1.4 is latest, but versions 0.5.1.3 and 0.5.1.4 require Shibuya 0.10 whereas Keiro currently requires Shibuya 0.9. The adapter-facing subscription API did not change between Kiroku 0.8.0.1 and 0.9.0.0, and Cabal successfully built the released 0.5.1.2 adapter with Kiroku 0.9. This keeps the real adapter the same version as the failing Kenshou cohort without upgrading Keiro's queue framework as part of a retention diagnosis. Results still need the Kiroku 0.9 version difference stated in attribution.
  Date: 2026-09-25

- Decision: when `KEIRO_RETENTION_BLOCKS` is unset, choose the first divisor of the requested operation count from six through twelve.
  Rationale: the specified 20,000-operation investigation is not divisible by the six-block default, while the gate needs at least five samples after warm-up and equal block sizes. This yields six blocks for 1,500 operations and eight for 20,000; an explicit blocks override remains available.
  Date: 2026-09-25

- Decision: keep separate controls for the raw Kiroku ack stream, the hand-built adapter bridge, and the released Shibuya adapter.
  Rationale: the raw stream tests delivery and ack bookkeeping, the bridge adds envelope and decision conversion, and the released adapter adds its own implementation. Comparing all three is stronger than treating a direct raw-stream consumer as if it exercised the bridge.
  Date: 2026-09-25

- Decision: split the combined Kiroku append/probe control into direct-append, transactional-append, and probe-only diagnostics while retaining the original combined leg.
  Rationale: the 20,000-operation combined burst retained large-object bytes even after a 60-second idle period, whereas the process-manager worker remained bounded. Separate controls are needed to distinguish direct append from duplicate probes and to compare the transactional append path the worker actually uses. The original combined leg remains a regression signal for the earlier observation.
  Date: 2026-09-25

- Decision: use unsnapshotted router targets in the default gate and `Every 100` target snapshots above 1,500 operations.
  Rationale: the ordinary gate preserves the reported workload's unsnapshotted targets. At 20,000 events and four fixed targets, repeated command history replay made the long diagnostic prohibitively expensive and entangled worker retention with plan 298's history question. The snapshotted variant keeps the same subscription, adapter, routing, fan-out, and ack path while bounding target replay cost. Record the policy with each result; do not use that variant alone to close BUG-1.
  Date: 2026-09-25

- Decision: assign the shared live-worker heap growth to Kiroku's empty-subscriber publisher update and close Keiro BUG-1 as a duplicate of `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3`.
  Rationale: both exact released-cohort worker info-table profiles name the same Kiroku `cheapAdvance` thunk and Hasql decoder, the Kiroku-only append path reproduces the large-object trend, and forcing that one scalar position in an isolated Kiroku 0.9.0.0 worktree holds large-object bytes flat. The expression is unchanged from the reported Kiroku 0.8.0.1 cohort to the current 0.9.0.0 release. Keiro's pre-appended worker controls test dispatch and ack retention but do not recreate the reporter's live publisher load. The upstream BUG-3 report and strict-update experiment are the hand-off; the temporary patch is not a released fix.
  Date: 2026-09-25

- Decision: keep Keiro's dependency versions for this plan.
  Rationale: upgrading Kiroku 0.8.0.1 to the latest released 0.9.0.0 does not remove the lazy publisher update, and the newer released Shibuya adapter versions require Shibuya 0.10 while Keiro uses 0.9. A dependency change would not fix the identified retention and would confound the released-cohort comparison.
  Date: 2026-09-25


## Outcomes & Retrospective


The in-repository `keiro-retention` suite now runs eleven isolated legs and prints
post-major live bytes, large-object bytes, thread counts, slope, growth, and a
two-floor verdict. All eleven default-size legs passed in asserting mode in
112.2 seconds; the process-manager and router legs were also bounded at 20,000
operations, with the router's long run explicitly snapshotted. The suite runs
from `just verify`, and ADR-48 records the measurement rule. The exact live
workload still reproduced both reported worker trends, so a passing pre-appended
worker leg alone would have been misleading. The complete `just verify` gate
passed on 2026-09-25 after the suite and report updates.

Both released-cohort worker info-table profiles identify the same Kiroku
publisher `cheapAdvance` thunk and Hasql decoder closures. Kiroku 0.8.0.1 and
0.9.0.0 both store the unevaluated `max` of the previous and new global
positions in a TVar when there is no all-stream queue subscriber. A direct
Kiroku append control reproduced the large-object growth, and a temporary
strict update in an isolated Kiroku worktree removed it in the same control.
Keiro BUG-1 is therefore a duplicate of
`mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3`, which remains confirmed
upstream. No Keiro runtime patch or package upgrade can remove the defect in
the current released Kiroku version. The temporary Kiroku patch is not part of
this repository or a release.

2026-09-25 release follow-up: Kiroku published the strict publisher update in
`mori://shinzui/kiroku/packages/kiroku-store` version 0.9.0.1. Keiro's
package bounds now require that version. BUG-1 remains a duplicate; the full
live-worker soak in the hand-off below has not
yet been rerun against the published package. The preceding paragraph records
the state when this plan's original attribution completed.

Kenshou hand-off: rerun
`keiro/command/soak/write-side-steady-state-reduced` for five minutes at
`command.rate-per-second=20`, `command.accounts=16`, `router.fanout=4`,
`projection.prune-interval-seconds=60`, and `pg.durability=durable`, profiling
both `keiro/pm-worker` and `keiro/router-worker`. Point its `cohort/head.project`
at a future Kiroku commit or release that forces the publisher position, while
preserving the released cohort as the failing baseline. The expected change is
that both child post-major live-byte slopes and large-object series settle and
the worker leak verdicts stop reporting growth; the nine durable SQL checks
must still pass. Kenshou's finding and `knownDefect` references can then be
updated by that repository. Mori cannot yet resolve BUG-3's artifact URI until
the registry is refreshed, but the canonical URI is recorded in both reports.


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
slope=  31 B/op  growth= 0.02 MiB  verdict=bounded
```

The fixture (`keiro/retention/Retention/Fixture.hs`). It defines, following
`keiro/bench/Main.hs`:

- A target aggregate `RetentionTarget` with commands `Credit Int` and events
  `Credited Int`, one control state, and no registers. The default target has
  `snapshotPolicy = Never` and `stateCodec = Nothing`; the longer router diagnostic
  uses an `Every 100` variant with a state codec. Both are validated with
  `mkEventStreamOrThrow`. Target stream names are `retentiontarget-<k>` for `k`
  in `0 .. 15`, so sixteen targets share the process-manager load like the sixteen
  Kenshou accounts. Kiroku treats the prefix before the first hyphen as the
  category, so the target and source prefixes must differ.
- A source event type `Signal { signalId :: Text, account :: Int }` stored in category
  `retentionsource` (stream `retentionsource-<signalId>`, one event per stream, so every
  source event has its own correlation id as Kenshou's transfers do) and a decoder
  `decodeSignal :: RecordedEvent -> Maybe (RecordedEvent, Signal)`.
- A process manager `retentionManager :: ProcessManager Signal ...` whose own aggregate is
  a one-state saga with command `Seen` and event `SeenRecorded`, `correlate = signalId`,
  `streamFor id = stream ("pm:retention-" <> id)`, and `handle signal = ProcessManagerAction
  { command = Seen, commands = [PMCommand (stream ("retentiontarget-" <> account)) (Credit 1)],
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
   `retentionplain-<k mod 16>` with `AnyVersion` and then `eventExistsInStream` for that
   id. Kiroku and hasql only.
3. `kiroku-append-only`: repeat the direct append without the existence probe.
4. `kiroku-append-tx`: use `runTransactionAppendingResource` for the same events,
   matching the worker's transactional append path.
5. `kiroku-probe-only`: preload the events, then perform the existence probes
   during measurement, so append allocations do not count toward its slope.
6. `kiroku-subscribe-ack`: before the loop, append `operations` source events; the loop is
   the consumer side of `subscriptionAckStream` replying `Continue` to every item, with the
   sampler driven every `blockSize` items. Kiroku's subscription worker and bridge only.
7. `hand-bridge-ack`: use the fixture's `ackAdapter` to convert the raw Kiroku
   ack stream into `Ingested` items, then consume and finalize them as `AckOk`.
8. `shibuya-adapter-ack`: use `Shibuya.Adapter.Kiroku.kirokuAdapter` with
   `defaultKirokuAdapterConfig` targeting only `retentionsource`; consume its source,
   finalize each item as `AckOk`, and call its `shutdown` at the operation limit. This
   measures the released adapter's envelope and ack conversion on the same kiroku
   subscription, without keiro dispatch. Match subscription configuration and fixture
   events across this leg and the worker legs.
9. `pm-worker`: pre-append the source events, then `runProcessManagerWorkerWith
   defaultWorkerOptions defaultRunCommandOptions retentionManager (sampleOnAck ...
   realAdapter) decodeSignal`, where `realAdapter` comes from `kirokuAdapter`. One
   operation is one delivered source event, which performs the
   manager append, the duplicate probes, and one target dispatch.
10. `router-worker`: as 9 with `runRouterWorkerWith` and fan-out four; use
   unsnapshotted targets at the default size and `Every 100` target snapshots
   above 1,500 operations, printing the policy for each run.
11. `projection-apply`: register a read model named `retention-activity` with
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
eleven tables and exits 0; the `baseline-no-store` table shows growth under 0.5 MiB. Tables for
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
  the two worker legs (the longer router run uses snapshotted target histories), and the Milestone 0 bands name only `Kenshou.*` closures or thread
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
11 examples, 0 failures
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

1. `cabal test keiro-retention` runs the eleven legs from an empty ephemeral database and
   prints one table per leg. With the default sizes the run finishes in well under five
   minutes on a laptop; if it does not, reduce `blockSize` before reducing `blocks`, because
   the verdict needs at least five kept samples.
2. `baseline-no-store`, `kiroku-append-probe`, `kiroku-subscribe-ack`, and
   `shibuya-adapter-ack` are `bounded`, or the plan's Decision Log records matching upstream
   attribution and BUG-1 is `duplicate` with the canonical upstream
   `duplicateOf` URI. Mori resolution may await artifact coverage or a
   refreshed registry.
3. `pm-worker` and `router-worker` are `bounded` at the default size and at 20,000
   operations, with the router's long run labeled as snapshotted. A terminal BUG-1
   status additionally needs a successful profile or equivalent matching evidence
   from the reported workload; a bounded snapshotted run alone does not supply it.
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
versions differ, so the implementation diffed the release tags in the kiroku checkout
(`git diff kiroku-store-v0.8.0.1 kiroku-store-v0.8.0.2 -- kiroku-store/src/Kiroku/Store/Subscription`
and the same for `shibuya-kiroku-adapter-v0.5.1.2..v0.5.1.3`). The results are in
Surprises & Discoveries above. The actual Keiro checkout now uses Kiroku 0.9.0.0,
which is a material version difference from the 0.8.0.1 failing cohort.


## Revision Notes


- 2026-09-24: Reviewed this plan with plan 298 and added a real-adapter control. Attribution
  now requires matching worker evidence before closing BUG-1 as an upstream duplicate;
  samples inside ack finalization are explicitly treated as provisional. This addresses
  the gap between the hand-built adapter and Kenshou's actual worker path.
- 2026-09-25: Recorded the implemented controls and measurements, added a distinct
  hand-built ack bridge leg, and defined a snapshotted target variant for the
  20,000-operation router diagnostic after unsnapshotted history replay dominated
  that run. The default gate remains unsnapshotted, and attribution still requires
  matching evidence from the original workload.
- 2026-09-25: Completed exact released-cohort info-table profiles for both worker
  roles, compared an isolated strict Kiroku publisher update with the released
  append control, filed upstream BUG-3, and closed Keiro BUG-1 as its duplicate.
  Recorded the repo gate, ADR, and Kenshou re-verification hand-off.
