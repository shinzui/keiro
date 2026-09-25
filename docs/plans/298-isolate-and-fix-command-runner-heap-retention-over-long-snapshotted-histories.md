---
id: 298
slug: isolate-and-fix-command-runner-heap-retention-over-long-snapshotted-histories
title: "Isolate and fix command-runner heap retention over long snapshotted histories"
kind: exec-plan
created_at: 2026-09-24T02:46:52Z
intention: "intention_01m38mx70deekbhtqefq54bpxx"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-24T02:46:52Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-24T03:08:03Z
      mode: "discuss"
      note: "Recorded the agreed verification-bound decisions: process-wide default limit of one, same-seed dedupe deferred, no replay timeout"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-25T21:01:52Z
      mode: "discuss"
      note: "Recorded Kiroku BUG-3 as a command-soak hypothesis and required a matched source-fix comparison before duplicate closure"
  reviews:
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T05:10:04Z
      verdict: "changes-requested"
      note: "Verification failure test contradicts encodeSnapshotStrict handling; spawn reservation and attribution need revision"
---

# Isolate and fix command-runner heap retention over long snapshotted histories

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


An aggregate with a long history is the normal case for a keiro service that has run for a
while: an account stream with ten thousand events hydrates from a snapshot plus a short
tail, and every command repeats that hydration. Bug report
[BUG-2](../bug-reports/2-command-workload-retains-heap-with-seed-verification-disabled.md)
records that when the external verification harness Kenshou ran a sustained command
workload against one such stream, the process's live heap after forced major collections
grew from 13 MB to 93 MB in 160 seconds, even with the sampled snapshot-seed verification
turned off, so the asynchronous verification cannot be the sole cause. Threads, file
descriptors, native memory, and PostgreSQL connections stayed flat. The report does not say
whether keiro, the kiroku event store, or the harness retains the memory.

After this plan, a keiro maintainer can run one command in this repository that seeds a
ten-thousand-event snapshotted stream, runs thousands of commands against it, and prints,
per block of commands, the live heap after a forced major collection with a `bounded` or
`retained` verdict; the same command isolates hydration from append and snapshot writing,
and isolates kiroku's read path from keiro's fold. That command is part of `just verify`.
Independently of where the retention is attributed, keiro stops spawning an unbounded
number of concurrent snapshot-seed verifications: the retained run data shows that at a
sample rate of one, a three-command-per-second workload over a ten-thousand-event stream
carried about 150 MB more live heap and twenty-one more threads than the same workload with
verification off, because each sampled hit launches a full replay that nothing throttles.
BUG-2 closes with a status grounded in the evidence: `fixed`, `duplicate` of an upstream
report, or `cannot-reproduce` with the analysis written into the report.

This plan is the second of two written for the two heap reports Kenshou filed on
2026-09-24. It uses the retention harness that
[plan 297](297-isolate-and-fix-write-side-worker-heap-retention-under-steady-subscription-load.md)
delivered (the `keiro-retention` test suite and its `Retention.Measure` module) and adds
command-runner legs to it. Plan 297 found an idle-publisher position thunk in Kiroku,
recorded as `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3`, and fixed it on
Kiroku master. The command soak also opens a store without subscribers and appends once
per command, so that fix is a strong hypothesis for its headline growth. A matched run
with only the Kiroku fix must confirm attribution before BUG-2 is closed. Milestone 4
(bounding verifications) stays in scope because it is keiro-owned regardless.


## Progress


- [x] (2026-09-24) Link this plan from the BUG-2 report body and record the link in `docs/bug-reports/log.md`; the bundle validated under `--strict`.
- [ ] Milestone 0: run Kenshou's closure-type profile of the reduced seed-backlog soak (main process, verification off) and record the growing bands in Surprises & Discoveries; run the info-table variant if the bands are byte arrays or thunks.
- [ ] Milestone 0: compare the released command soak with the same cohort using only the Kiroku BUG-3 strict-position fix; capture resolved package versions and post-major live and large-object trends before assigning BUG-2 ownership.
- [ ] Milestone 1: add the snapshotted ledger fixture and the seeding helper to plan 297's existing `keiro-retention` suite.
- [ ] Milestone 1: add the `command-long-history`, `hydrate-only`, `kiroku-read-tail`, and `command-short-history` legs; run them in report-only mode and record the tables.
- [ ] Milestone 1: add the informational `command-long-history-verify-every` leg and record its thread column before Milestone 4.
- [ ] Milestone 2: decide attribution from Milestones 0 and 1 together with plan 297's outcome, record it, and move BUG-2 to `confirmed` or to its terminal status.
- [ ] Milestone 3 (only if keiro owns the retention): profile the retained leg, fix the retaining code, and make the leg an asserting gate.
- [ ] Milestone 4: bound in-flight snapshot-seed verifications per process, count skipped samples, cover with tests, and document the bound.
- [ ] Milestone 5: changelog, documentation, report closure with `resolution`, bundle validation, and ADR distillation.


## Surprises & Discoveries


- 2026-09-25: Plan 297 attributed the write-side worker profiles to Kiroku's
  empty-subscriber publisher position thunk and filed
  `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3`. The strict update
  passed a Kiroku regression test that failed before the change and reduced
  large-object retention in an isolated 20,000-append Keiro control. Kenshou's
  command soak calls `withFixtureTelemetryEnv`, which opens one Kiroku store
  without subscribing, and every measured `Deposit` command appends one event.
  Its 21,527-command run reached 85.8 MB of large objects. This makes BUG-3
  a plausible shared cause, but the command soak has not been rerun with the
  fix; its larger per-command growth may include another source.


## Decision Log


- Decision: depend on plan 297's harness instead of building a second one.
  Rationale: both reports show the same per-operation large-object growth, and one
  measurement primitive with different legs is enough to separate the command runner, the
  kiroku read path, and the harness. Plan 297 is checked in, so this plan incorporates it by
  reference and restates only what its legs need.
  Date: 2026-09-24

- Decision: test the Kiroku BUG-3 fix against the exact command-soak cohort
  before classifying BUG-2 as an upstream duplicate or investigating Keiro's
  hydration path as the primary retaining site.
  Rationale: the reported soak has no publisher queue subscribers and appends
  once per successful command, so it exercises the same Kiroku path that plan
  297 isolated. The store's strict-position fix is on master but is unreleased;
  a backport onto the released 0.8.0.1 source in an otherwise identical cohort
  is needed to test causality. The verification fan-out remains independent.
  Date: 2026-09-25

- Decision: seed the long history with raw appends and one command, not with ten thousand
  commands.
  Rationale: `Keiro.Command` writes a snapshot only when an append crosses a multiple of the
  policy interval. Appending 9,999 events directly and then running one command reaches
  version 10,000 and writes the snapshot in a few seconds; afterwards every measured command
  hydrates from a snapshot at most 99 events behind the head, which is exactly the steady
  state Kenshou measured (Kenshou seeded through the command runner every hundredth event
  to accumulate intermediate snapshots, which the steady state does not need).
  Date: 2026-09-24

- Decision: use the exported `Keiro.Command.hydrate` for a hydration-only leg rather than a
  no-op command.
  Rationale: it isolates snapshot lookup, tail reading, decoding, and the keiki fold from
  append and snapshot writing without inventing a silent edge in the fixture aggregate.
  Date: 2026-09-24

- Decision: bound in-flight snapshot-seed verifications in this plan even though BUG-2 was
  observed with verification disabled.
  Rationale: the retained controlled-pair runs show the unbounded fan-out directly (about
  150 MB more live heap and twenty-one more Haskell threads at sample rate one), Kenshou's
  own leak guide names "fire-and-forget snapshot-seed verification in keiro" as a lead, and
  the fix is keiro-owned whatever the attribution of the headline growth turns out to be.
  Date: 2026-09-24

- Decision: the Kenshou repository is read-only for this plan, exactly as in plan 297.
  Rationale: this plan runs the `kenshou` command line and reads retained run directories;
  Kenshou's finding record and `knownDefect` references are updated by that repository once
  BUG-2 reaches a terminal status.
  Date: 2026-09-24

- Decision: the in-flight verification bound is a process-wide counter with a default limit of
  one, exposed as the `seedVerifyInFlightLimit` options field; no caller-supplied gate type is
  added now.
  Rationale: discussed and agreed on 2026-09-24. Safe by default is the property that matters:
  a gate the application must allocate and thread through its options would silently restore
  the fan-out wherever it is forgotten. A process-wide counter follows the two process-wide
  values this path already relies on (the sampler's global random generator in keiro and
  kiroku's process-local hook references). One shared budget per process is the right shape
  for a memory bound. An application-owned gate can be added later as an additive field if a
  service ever needs separate budgets. A limit of zero or less restores the old behaviour so
  the change is reversible per caller without a code change.
  Date: 2026-09-24

- Decision: same-seed deduplication (verifying each snapshot seed at most once) is deferred and
  is not part of this plan.
  Rationale: discussed and agreed on 2026-09-24. At the default sample rate of one in a
  thousand, re-verifying the same seed is rare, so the waste it would remove is small in
  production; at sample rate one the in-flight bound already caps the cost to one replay
  running back to back, which is what that rate asks for. An in-memory memo keyed by stream
  name is a new structure that stays bounded only if it is made durable, and the durable
  variant (a verified flag on the snapshot row in `keiro.keiro_snapshots`) is a schema
  migration and changes the semantics from "a sampled fraction of hits" to "each snapshot at
  most once". That deserves its own decision rather than riding on this fix. If it is taken
  up later, the durable variant is the one to build; an unbounded in-memory map must not be
  introduced by a plan whose subject is heap retention.
  Date: 2026-09-24

- Decision: no timeout or length cap on a verification replay.
  Rationale: discussed and agreed on 2026-09-24. Replay length is bounded by the stream, the
  store's statement timeout covers a hung query, and Milestone 4 already makes failures
  visible through a counter and a log line. A timeout would add a cancellation path to reason
  about for a case with no evidence behind it.
  Date: 2026-09-24


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


### The report and the bundle


`docs/bug-reports/` is an OKF bundle (OKF is the house Markdown-plus-frontmatter format
validated by `okf` and indexed by `mori`) governed by the shared `coordination.bugReports`
profile imported through `mori/bug-reports-profile.dhall`. Its `status` vocabulary is
`reported`, `confirmed` (this repository reproduced it), `in-progress`, and the terminal
values `fixed`, `wont-fix`, `duplicate`, `not-a-bug`, and `cannot-reproduce`. Terminal
statuses need a `resolution` line; `fixed` needs `fixedVersion` (`unreleased` while only on
`master`); `duplicate` needs `duplicateOf`, which may be an external `mori://` URI. Every
change is logged with `okf log add docs/bug-reports ...` and checked by
`just bug-reports-validate`, part of `just verify`.

The report is
`docs/bug-reports/2-command-workload-retains-heap-with-seed-verification-disabled.md`,
handle `BUG-2`, `status: reported`, `severity: degraded`, `affectedVersion: 0.17.0.0`,
intended canonical handle `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-2` (the
registry had not indexed the bundle when this plan was written; verify with `mori path`
after the next refresh). The reporter is `mori://shinzui/keiro-runtime-kenshou`, checked out
at `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`; its finding is
`docs/findings/2-keiro-seed-backlog-heap-growth.md` there, and the run directories
`runs/01a0d0f6-822c-7427-a4c9-0a84cd11329c/` (the reported run),
`runs/01a0d100-8ad4-7623-b71f-251c8e530d06/` (controlled pair, sample rate zero), and
`runs/01a0d0fe-3721-70b3-b8f4-eff1677fb44c/` (controlled pair, sample rate one) are still on
disk under that checkout. All are read-only inputs.


### The command runner over a snapshotted stream


A command in keiro is processed by `Keiro.Command.runCommand`
(`keiro/src/Keiro/Command.hs` line 781): hydrate the aggregate, run the keiki transducer to
decide, append the emitted events with optimistic concurrency, and retry a conflict up to
`retryLimit` times. Hydration is the part that scales with history:

- `hydrate` (line 410, exported) calls `hydrateAfterProbe` (line 438). When the stream has
  a `stateCodec`, it asks `Keiro.Snapshot.lookupSnapshotSeed`
  (`keiro/src/Keiro/Snapshot.hs` line 77) for the latest snapshot row whose three codec
  discriminators match, decodes it into a `SnapshotSeed` (folded state, register file,
  stream version), and calls `hydrateSeeded` (line 501) from that version. Without a usable
  snapshot it calls `hydrateFull` (line 479) from version zero.
- `hydrateSeededThrough` (line 521) reads the tail with kiroku's `readStreamForwardStream`
  (`Kiroku/Store/Read.hs` line 67 in the kiroku checkout) in pages of `pageSize` (default
  256), groups each page with `Streamly.foldMany (Fold.take groupSize Fold.toList)`, and
  folds pages with `Fold.foldlM'` whose accumulator is
  `Either CommandError (Keiki.InFlight s co, RegFile rs, Maybe RecordedEvent)`. Each page is
  decoded by `decodePrefix` (gap detection plus event codec) and applied with
  `Keiki.replayEvents` (keiki `src/Keiki/Core.hs` line 2062, strict in the event index).
  `finishReplay` demands a `Keiki.Settled` wrapper and builds the `Hydrated` value, whose
  fields are strict.
- After a successful append, `verifyAndSnapshot` (line 1278) applies the appended events to
  the pre-command state, evaluates `Keiro.Snapshot.Policy.shouldSnapshotSpan` for the
  policy, and on a hit encodes the state with `encodeSnapshotStrict` (which `force`s the
  JSON value) and upserts it with `writeSnapshotEncoded`.
- On a snapshot hit, `scheduleSeedVerification` (line 660) decides whether to sample this
  hydration. With `seedVerifySampleRate <= 0` it does nothing. With rate one it always
  samples; otherwise one in `rate`. A sampled hit runs `verifySnapshotSeed` (line 682) as a
  detached thread (`void $ runConcurrent $ Async.async ...`): a full replay from version
  zero through the seed version, canonical JSON comparison, and on divergence a stderr line
  plus the `keiro.snapshot.seed.divergence` counter. Nothing bounds how many such replays
  run at once, nothing cancels them, and an exception inside one is lost with the handle.

Metrics were `Nothing` and the tracer was `Nothing` in the failing runs, so the counters in
`keiro/src/Keiro/Telemetry.hs` are no-ops there. Nothing in this path holds state across
commands by construction: the only long-lived values are the `KirokuStore` handle (its
hasql pool, notifier, and publisher), the `RunCommandOptions` record, and the validated
`EventStream`. A per-command retention inside keiro therefore has to escape through one of
those or through a spawned thread.


### The Kenshou scenario


`kenshou-keiro/src/Kenshou/Suite/Keiro/Command/Soak.hs` in the Kenshou checkout defines
`keiro/snapshot/soak/seed-verification-backlog-reduced`. It opens one kiroku store with a
pool of thirteen, opens one account stream whose policy is `SnapEvery 100`, seeds
`command.stream-length` (10,000) events by appending ninety-nine raw `Deposited` events per
hundred and running one `runCommand` deposit at each multiple of one hundred (so a snapshot
exists at every hundred), and then runs a closed-loop load of one worker calling
`runCommand` with `seedVerifySampleRate` set from the knob, `verifyReplayOnAppend` left at
its default `True`, and no metrics or tracer. The opt-in `diagnose.major-gc-interval-ms`
probe forces a major collection every ten seconds and writes `series/rts-major.csv`. The
measurement session also samples the RTS, the process, and six PostgreSQL views once per
second and records latencies in a histogram recorder.


### What the retained run data shows


The reported run (`01a0d0f6-822c-7427-a4c9-0a84cd11329c`, closed loop, one worker,
sample rate zero) has these forced-collection samples in `series/rts-major.csv`:

```text
t (s)   live_bytes after forced major GC
  0        8,867,856
 10       13,313,480
 20       17,697,536
 ...
160       87,422,608
170       92,774,928
```

The one-hertz `series/rts.csv` shows the growth is almost entirely large objects
(`large_objects_bytes` 1.0 MB at start, 85.8 MB at 177 s), Haskell threads flat at 11, and
resident set size 77 MB to 166 MB. Over 21,527 completed commands that is about 3.7 KB
retained per command, the same per-operation signature plan 297 found in every Kenshou
child process of the write-side soak, including one that runs no keiro code except
`applyAsyncProjection`.

The controlled pair used an open constant load with 256 executor threads (266 and 287
Haskell threads in the two arms). Both arms started their steady window near 154 MB, grew
to about 221 MB over eighty seconds, and then plateaued. With only 391 commands per arm,
that plateau is per-executor state warming up, not per-command retention; a 256-executor
load model is therefore the wrong shape for attribution and Milestone 0 keeps the closed
loop. The sample-rate-one arm additionally carried about 150 MB more live heap at the same
instants (`live_bytes_last_gc` 333 to 384 MB against 174 to 221 MB) and twenty-one more
Haskell threads: that is the unbounded verification fan-out Milestone 4 removes.

Consequences for this plan:

1. The command soak is likely exercising the same Kiroku idle-publisher
   retention as the write-side workers: it has no publisher queue subscribers
   and each successful command appends. This is a hypothesis until a matched
   run with the Kiroku fix flattens the trend. Keiro or Kenshou may contribute
   additional growth, so the harness must still separate the command runner
   from Kiroku's read path and from the harness itself.
2. Because the retained objects are large, a closure-type profile names them directly
   (`ARR_WORDS`, `STACK`, `THUNK`, or a constructor whose module prefix attributes it).
3. Verification fan-out is a separate, keiro-owned defect with direct evidence.

Hasql fact checked for this plan: no kiroku or keiro statement builds SQL text per call, so
hasql's per-connection prepared-statement registry is bounded and not a candidate.


### Existing tooling this plan reuses


- Plan 297 delivered the `keiro-retention` test suite under `keiro/retention/`
  with `Retention.Measure` (forced major collection, `GHC.Stats` sample, least-squares slope,
  `Bounded`/`Retained` verdict, table rendering, and the environment variables
  `KEIRO_RETENTION_OPERATIONS`, `KEIRO_RETENTION_BLOCKS`, `KEIRO_RETENTION_LEGS`,
  `KEIRO_RETENTION_REPORT_ONLY`), `Retention.Fixture`, and `Retention.Legs` with a `Leg`
  record and `allLegs`. This plan adds a fixture and legs to those modules; the
  interfaces it needs are restated under Interfaces and Dependencies.
- `keiro-test-support/src/Keiro/Test/Postgres.hs`: `withMigratedSuite` and
  `withFreshResourceStore` give each leg a fresh migrated ephemeral database and a
  `StoreRunner`.
- `keiro/test/Main.hs` already defines a snapshot-capable aggregate with a register file:
  search for `SnapshotCounterRegs` and `defaultStateCodec @SnapshotCounterRegs @CounterState 1`
  (around line 2435). The ledger fixture copies that transducer and codec.
- `keiro/bench/Main.hs` shows raw seeding with `appendToStream` in chunks (`chunksOf`,
  `seedChunkSize`), and `benchEventCodec` shows how to encode events with the aggregate's
  own codec so that hydration decodes seeded events exactly like appended ones.
- `Keiro.Snapshot.Schema.lookupSnapshotRow` (`keiro/src/Keiro/Snapshot/Schema.hs` line 93)
  returns the stored snapshot row for a stream id regardless of codec; the legs use it to
  assert the seed snapshot exists at version 10,000 before measuring.
- Kenshou's `kenshou diagnose profile SCENARIO --mode closure-type|info-table` runs a
  scenario under `-hT` or `-hi` and writes an event log under `--out`; the main process is
  profiled when `--worker` is omitted. `just diagnose-tools` in that checkout installs
  `eventlog2html` into `.dev/bin`, and `just diagnose-build-info-table` builds the
  info-table variant.


### Architecture decision records


[ADR-48](../adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md)
now defines the post-major-GC retention gate and its isolated legs; this plan extends it
in Milestone 5. Three other local records constrain the work:

- [ADR-3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md): a
  snapshot is reused only when codec version, register-layout hash, and control-state hash
  all match. The fixture must keep one codec for the whole leg so every hydration hits the
  seed; a leg that accidentally changes the codec would fall back to full replay and
  measure the wrong path.
- [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md)
  and [ADR-24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md):
  any fix in the hydration or append path must leave replay identity and deterministic ids
  untouched; the existing replay-compatibility suites (`ReplayCompatibilitySpec` and the
  `just replay-compatibility` gate) are the check.
- [ADR-25](../adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md):
  by analogy, a bounded verification must never let a skipped or failed verification affect
  the command's result; the command already succeeded before verification is scheduled.

The cross-repository record behind the reporter's method is Kenshou's ADR-10, "Judge heap
leaks on live bytes after major collections" (`docs/adr/0010-judge-heap-leaks-on-live-bytes-after-major-collections.md`
in that checkout; intended handle
`mori://shinzui/keiro-runtime-kenshou/okf/adrs/concepts/ADR-10`, unresolved by the registry
at writing time). The harness judges the same way and never from `max_live_bytes` or
resident set size.


## Plan of Work


### Milestone 0: attribute with Kenshou's own profiling recipe


Scope: no keiro code. Run the reduced seed-backlog soak under a closure-type heap profile
of the main process with verification off and the report's closed-loop load, then read the
growing bands. Run the info-table variant if the bands are byte arrays or thunks. At the
end, Surprises & Discoveries holds the top growing closure types and the Decision Log holds
a first hypothesis. The forced-collection knob is unnecessary here because `-hT -i5` already
forces a census every five seconds.

Also compare the original released cohort with a detached checkout of
`mori://shinzui/kiroku` at tag `kiroku-store-v0.8.0.1` carrying only BUG-3's
strict-position update. Keep
Keiro, Kenshou, PostgreSQL settings, load model, command history length,
verification sample rate zero, and duration identical. Use a temporary Cabal
project to substitute that local `kiroku-store` package and inspect the resolved
Cabal plan to confirm that this is the only source change. Record post-major
live-byte and large-object series for both runs. Kiroku master uses a later
schema, so substituting its whole package into the released cohort would not
be an equivalent comparison. If the fixed run still grows, continue with the
profile and command legs to isolate the remainder.

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou
nix develop -c just diagnose-tools
nix develop -c cabal run kenshou -- diagnose profile \
  keiro/snapshot/soak/seed-verification-backlog-reduced \
  --mode closure-type --interval-s 5 \
  --set command.stream-length=10000 --set snapshot.seed-verify-sample-rate=0 \
  --set soak.duration-minutes=3 \
  --dim pg.durability=durable --out .dev/profiles
```

Render the event log with `.dev/bin/eventlog2html <eventlog> -o <html>` and open the
detailed view. Apply the same reading as plan 297: a growing `STACK` band with flat thread
counts means a thread's stack keeps growing (a non-tail-recursive loop); `ARR_WORDS` means
retained byte arrays (payload bytes, hasql buffers, encoded JSON, or histogram arrays);
a constructor band attributes by module prefix (`Kenshou.`, `Kiroku.`, `Keiro.`, `Hasql.`,
`Database.PostgreSQL.LibPQ.`). For the info-table variant:

```bash
nix develop -c just diagnose-build-info-table
BIN=$(nix develop -c cabal --project-file=cabal.diagnose-info-table.project \
  --builddir=dist-diagnose/info-table list-bin kenshou-cli:exe:kenshou)
nix develop -c "$BIN" diagnose profile \
  keiro/snapshot/soak/seed-verification-backlog-reduced \
  --mode info-table --interval-s 5 \
  --set command.stream-length=10000 --set snapshot.seed-verify-sample-rate=0 \
  --set soak.duration-minutes=3 \
  --dim pg.durability=durable --out .dev/profiles
```

Acceptance: the profile directory exists under `.dev/profiles` in the Kenshou checkout, the
bands are summarised in this plan with the directory name, and the Decision Log records the
hypothesis. If the run cannot start on this machine, record why and continue; Milestone 1
does not depend on it. For the matched comparison, record both run directories,
resolved Kiroku versions, and post-major slopes; do not infer duplication from
the shared code path alone.


### Milestone 1: command-runner legs in the retention harness


Scope: add a snapshotted ledger fixture and five legs to the `keiro-retention` suite. At the
end, `KEIRO_RETENTION_REPORT_ONLY=1 cabal test keiro-retention` prints a table for each new
leg, and each leg has asserted its own correctness before judging heap.

The fixture (`keiro/retention/Retention/Fixture.hs`, additions). Define `RetentionLedger`:
a copy of the test suite's snapshot counter aggregate (`SnapshotCounterRegs`, `CounterState`,
its transducer and event codec from `keiro/test/Main.hs`) renamed for the harness, with
commands `Deposit Int` and events `Deposited Int`, one integer register holding the balance,
`snapshotPolicy = Every 100`, and `stateCodec = Just (defaultStateCodec 1)`. Validate it once
with `mkEventStreamOrThrow "retention-ledger"`. Add `seedLedger :: StoreRunner -> Stream
RetentionLedgerStream -> Int -> IO ()` which appends `n - 1` `Deposited 1` events encoded
with the ledger's own event codec (so metadata carries the codec's `schemaVersion` key
exactly as a command append would) in chunks of 500 with `appendToStream ... AnyVersion`,
then runs one `runCommand defaultRunCommandOptions {seedVerifySampleRate = 0} ledger target
(Deposit 1)`, and finally asserts with `lookupSnapshotRow` that the stream's snapshot row is
at version `n`. Seeding 10,000 events this way takes seconds.

The legs (`keiro/retention/Retention/Legs.hs`, appended to `allLegs` after plan 297's):

1. `command-long-history`: seed 10,000; per operation `runCommand options ledger target
   (Deposit 1)` with `options = defaultRunCommandOptions {seedVerifySampleRate = 0}`
   (`verifyReplayOnAppend` stays `True` as in the report). Assert every result is
   `Right (Right r)` with `r.eventsAppended == 1`, and after the loop assert the stream
   version is `10000 + operations` and the snapshot row version is the last multiple of 100.
   This is the report's workload.
2. `hydrate-only`: seed 10,000; per operation `hydrate options ledger target` (the exported
   function) and assert `Right h` with `h.streamVersion == StreamVersion 10000`. Isolates
   snapshot lookup, tail read, decode, and fold from append and snapshot writing.
3. `kiroku-read-tail`: seed 10,000 with raw appends only; per operation
   `lookupStreamId` plus `readStreamForward name (StreamVersion 9900) 256` from kiroku and
   assert the page has 100 events. Kiroku's read path alone.
4. `command-short-history`: sixteen fresh `RetentionTarget` streams from plan 297's fixture
   (`snapshotPolicy = Never`); per operation `runCommand` a `Credit 1` to target `k mod 16`.
   The command runner without snapshots or long history.
5. `command-long-history-verify-every` (informational, never asserted): as leg 1 with
   `seedVerifySampleRate = 1`. Its table's `threads` column is the evidence for Milestone 4;
   record it before and after that milestone. Because this leg spawns replays, it runs last
   and its database is discarded like the others.

Each leg runs under `withFreshResourceStore`, and the worker-free legs use
`Retention.Measure.measureLeg` directly. The `hydrate-only` and `command-*` legs call keiro
through the `StoreRunner` (its effect stack is `'[Store, Error StoreError,
KirokuStoreResource, IOE]`, which satisfies `runCommand` and `hydrate`).

Acceptance: from the repository root,
`KEIRO_RETENTION_LEGS=command-long-history,hydrate-only,kiroku-read-tail,command-short-history KEIRO_RETENTION_REPORT_ONLY=1 cabal test keiro-retention --test-show-details=direct`
prints four tables and exits 0, and the tables are copied into Surprises & Discoveries with
the verification-every table and its thread column.


### Milestone 2: attribute and re-status the report


Scope: decide which layer retains, using the Milestone 0 bands, the Milestone 1 tables, and
plan 297's Milestone 2 outcome. The decision tree:

- `command-long-history` retains while `hydrate-only`, `kiroku-read-tail`, and
  `command-short-history` are bounded: keiro's append-and-snapshot path over a long history
  owns it. Set `status: confirmed`; continue to Milestone 3 with the snapshot write path
  (`verifyAndSnapshot`, `encodeSnapshotStrict`, `writeSnapshotEncoded`) as the first suspects.
- `hydrate-only` retains while `kiroku-read-tail` is bounded: keiro's page fold owns it. Set
  `status: confirmed`; continue to Milestone 3 with `hydrateSeededThrough` as the first
  suspect (its `Fold.foldlM'` accumulator tuple and `decodePrefix` are the places where a
  page could be kept alive past its fold).
- `command-short-history` retains as much per operation as `command-long-history`: the
  runner retains independently of history. If plan 297's `kiroku-append-probe` also
  retains, the store layer owns it; otherwise set `status: confirmed` and go to Milestone 3
  with `domainCommandAttempts` and `recordCommandOutcome` as the first suspects.
- The matched command soak flattens with only the BUG-3 fix: close BUG-2 as
  `duplicate` of `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3`, citing
  both slopes and the version-locked comparison. Skip Milestone 3. If the
  matched run still retains, use the command legs and profile to assign the
  remaining growth; file a distinct Kiroku report only if they isolate a
  distinct Kiroku defect.
- Every leg bounded at the default size and at `KEIRO_RETENTION_OPERATIONS=20000` for
  `command-long-history`, and Milestone 0's bands name only `Kenshou.*` closures or
  executor stacks: close BUG-2 as `cannot-reproduce` with a `resolution` citing the tables
  and the bands, and write the Kenshou hand-off. Skip Milestone 3.

In every case edit the report's frontmatter (`status`, `resolution` when terminal,
`duplicateOf` when duplicate, `generated.by: process:claude-code`, `generated.at` now) and
append an "Attribution" paragraph to the body naming the legs and verdicts. Then:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
okf log add docs/bug-reports --kind Update -m "BUG-2 <new status>: <one-line reason>"
just bug-reports-validate
```

Acceptance: the bundle validates under `--strict` and the Decision Log records the
attribution with its evidence.


### Milestone 3: fix a keiro-owned retention and make the leg a gate


Scope: only after `confirmed`. Profile the retaining leg alone with the ordinary build:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
KEIRO_RETENTION_LEGS=command-long-history KEIRO_RETENTION_OPERATIONS=6000 \
  KEIRO_RETENTION_REPORT_ONLY=1 cabal test keiro-retention --test-show-details=direct \
  --test-options='+RTS -hT -i0.5 -l-agu -RTS'
```

Render `keiro-retention.eventlog` with `eventlog2html` (install with
`cabal install --ignore-project --installdir=.dev/bin --install-method=copy eventlog2html-0.12.0`).
If the band is `ARR_WORDS` or `THUNK`, use the info-table project file that plan 297
introduces (`cabal.retention-info-table.project` with `-finfo-table-map
-fdistinct-constructor-tables`) and rerun with `+RTS -hi -i0.5 -l-agu -RTS` to get allocation
sites.

Fix the retention at the named site. Constraints: `runCommand` returns the same results,
writes the same snapshot rows at the same versions, and keeps replay identity untouched;
prove the last with `just replay-compatibility` and `cabal test keiro-test`. Make the
retaining leg assert `Bounded` by default. Record the before-and-after tables in Surprises &
Discoveries.

Acceptance: `cabal test keiro-retention` passes with the leg asserting; `just haskell-verify`
and `just replay-compatibility` pass.


### Milestone 4: bound in-flight snapshot-seed verifications


Scope: keiro-owned regardless of attribution. Today `scheduleSeedVerification` launches a
detached full replay for every sampled snapshot hit. Under a sample rate of one and a
ten-thousand-event stream, three commands per second launch replays faster than they finish,
which the pair runs show as twenty-one extra threads and about 150 MB of extra live heap.

Change `keiro/src/Keiro/Command.hs` so that at most `seedVerifyInFlightLimit` verifications
run at once per process, with a default of one. Add the field `seedVerifyInFlightLimit ::
!Int` to `RunCommandOptions` (documented next to `seedVerifySampleRate`; a value of zero or
less means unbounded, which preserves the old behaviour for callers who ask for it) and set
it to `1` in `defaultRunCommandOptions`. Keep the count in a process-wide
`TVar Int` created once with `unsafePerformIO` and marked `NOINLINE`, the same pattern the
kiroku subscription worker uses for its process-local hook references and the same scope as
the `globalStdGen` the sampler already uses. `scheduleSeedVerification` then does: decide
the sample as today; if sampled, atomically read the count and, when it is below the limit,
increment it and spawn the verification wrapped so that the count is decremented in a
`finally` and any synchronous exception is reported through a new
`keiro.snapshot.seed.verification.failed` counter and a stderr line of the same JSON shape
as `reportSeedDivergence`; when the count is at the limit, skip and increment a new
`keiro.snapshot.seed.skipped` counter. Add both counters to `Keiro.Telemetry` following the
existing `keiroSnapshotSeedDivergenceName` and `recordSnapshotSeedDivergence` pattern and to
the `KeiroMetrics` record. Adding record fields is a breaking change for code that builds
`KeiroMetrics` directly rather than through `newKeiroMetrics`; the 0.17.0.0 changelog set the
precedent for stating this.

Tests, in `keiro/test/Main.hs` next to the existing snapshot-seed verification examples
(search for `seedVerifySampleRate`): with an in-memory meter provider (the pattern at line
700 of that file), a stream seeded with enough events that a full replay takes noticeably
longer than a command, a sample rate of one, and a limit of one, run twenty commands and
assert that `keiro.snapshot.seed.skipped` plus the number of verifications that ran equals
twenty, that `listThreads` never exceeds the pre-loop count plus the limit plus the test's
own threads, and that every command still succeeded. A second example with the limit set to
zero shows the unbounded behaviour is still available. A third makes the verification throw
(a codec whose encoder errors) and asserts the count returns to zero and the failure counter
is one.

Documentation: extend the "Snapshot seed verification is sampled, not exhaustive" paragraph
in `docs/user/production-status.md` and the "Hydration Behavior" section of
`docs/user/snapshots.md` with one sentence each on the bound and the two counters, and add
the counters to the metrics table in `docs/user/operations.md` under "Observability". Keep
`docs/user/log.md` and `just user-documentation-validate` green.

Acceptance: the three new examples pass; the informational
`command-long-history-verify-every` leg now shows a flat `threads` column; the counters
appear in the documentation.


### Milestone 5: changelog, report closure, ADR


Scope: finish the paperwork. Add `keiro/CHANGELOG.md` entries under `## [Unreleased]`:
"Breaking Changes" for the `KeiroMetrics` fields, "New Features" for the verification bound
and counters, "Bug Fixes" for a keiro-owned retention fix naming BUG-2, and "Other Changes"
for the new legs. When keiro owned the retention, set the report to `status: fixed`,
`fixedVersion: unreleased`, with `resolution`, log it, and validate. Write the Kenshou
hand-off in Outcomes & Retrospective: scenario id, knobs, the expected verdict change, and
the note that Kenshou's comparison project must resolve the fixing Kiroku source
or Keiro commit before the reduced soak can re-verify it. Extend
[ADR-48](../adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md)
with the command-runner gate and with the decision that
snapshot-seed verification is bounded per process; run `okf log add docs/adr ...` and
`just adr-validate`.

Acceptance: `just verify` passes; the bug-report and ADR bundles validate; the CHANGELOG
entries exist; Outcomes & Retrospective is written.


## Concrete Steps


All commands run from `/Users/shinzui/Keikaku/bokuno/keiro` inside `nix develop`, except the
Milestone 0 commands, which run from the Kenshou checkout as shown.

The tracking link in the report was added when this plan was created (see Progress), so
start at Milestone 0. Compare the unchanged released command soak with the
single-change Kiroku BUG-3 backport before closing BUG-2; follow the same
Kenshou scenario command and settings shown under Milestone 0 in each cohort.

Build and run the new legs (Milestone 1):

```bash
cabal build keiro:test:keiro-retention
KEIRO_RETENTION_LEGS=command-long-history,hydrate-only,kiroku-read-tail,command-short-history \
  KEIRO_RETENTION_REPORT_ONLY=1 cabal test keiro-retention --test-show-details=direct
```

Expected transcript shape (numbers will differ):

```text
Retention legs
  command-long-history
leg=command-long-history operations=1500 blocks=6 block=250
block  ops   live_bytes   large_objects_bytes  threads
    1  250    3,402,112            1,769,472       11
    2  500    3,410,568            1,769,472       11
...
slope=  24 B/op  growth= 0.04 MiB  verdict=bounded
  hydrate-only
...
4 examples, 0 failures
```

Record the verification fan-out before Milestone 4:

```bash
KEIRO_RETENTION_LEGS=command-long-history-verify-every KEIRO_RETENTION_REPORT_ONLY=1 \
  cabal test keiro-retention --test-show-details=direct
```

Scale for investigation:

```bash
KEIRO_RETENTION_LEGS=command-long-history KEIRO_RETENTION_OPERATIONS=20000 \
  KEIRO_RETENTION_REPORT_ONLY=1 cabal test keiro-retention --test-show-details=direct
```

Run the verification-bound tests (Milestone 4):

```bash
cabal test keiro-test --test-options='-m "seed verification"'
```

Commit after each milestone with both trailers:

```text
ExecPlan: docs/plans/298-isolate-and-fix-command-runner-heap-retention-over-long-snapshotted-histories.md
Intention: intention_01m38mx70deekbhtqefq54bpxx
```


## Validation and Acceptance


The plan is complete when all of the following hold:

1. `cabal test keiro-retention` runs the command legs from an empty ephemeral database,
   prints one table per leg, and finishes with plan 297's legs in well under five minutes
   on a laptop. Seeding 10,000 events per leg is included in that budget; if it is not,
   seed once per suite into a template and clone it, but only after measuring.
2. `command-long-history` is `bounded` at the default size and at 20,000 operations, either
   because it always was (BUG-2 is then `cannot-reproduce` or `duplicate` with the evidence
   written into the report) or because Milestone 3 fixed it (BUG-2 is then `fixed`).
3. With sample rate one and limit one, the verification-every leg's `threads` column is
   flat, and the three new `keiro-test` examples pass.
4. `just verify` passes, including the retention suite, replay compatibility, and the
   bug-report, ADR, and user-documentation bundle validations.
5. The report body names the legs and verdicts so a reader can rerun the attribution.
6. BUG-2 is not marked `duplicate` of Kiroku BUG-3 unless the matched command
   soak's post-major live and large-object trends flatten with only that fix.


## Idempotence and Recovery


Every leg runs in a freshly cloned database and can be rerun at will; seeding is part of the
leg. Profiles and event logs live under `.dev/` in either repository and are not committed.
If a Kenshou profile run leaves child processes behind, `pkill -f 'kenshou worker'` in that
checkout is safe. The `RunCommandOptions` field and the `KeiroMetrics` fields are additive
in behaviour (default limit one changes only how many verifications overlap); if the bound
proves too strict for a consumer, the documented `0` value restores the old behaviour
without a code change. Report edits are corrected with a further `okf log add` entry rather
than by rewriting the log.


## Interfaces and Dependencies


Delivered by plan 297, in `keiro/retention/Retention/Measure.hs`:

```haskell
data HeapSample = HeapSample
  { operations :: !Int, liveBytes :: !Word64, largeObjectBytes :: !Word64, threads :: !Int }
data Verdict = Bounded | Retained
data GateConfig = GateConfig
  { blocks :: !Int, blockSize :: !Int, warmupBlocks :: !Int
  , slopeFloorBytesPerOp :: !Double, growthFloorBytes :: !Word64, reportOnly :: !Bool }
gateConfigFromEnvironment :: IO GateConfig
measureLeg :: GateConfig -> Text -> (Int -> IO ()) -> IO (Verdict, [HeapSample])
```

and in `keiro/retention/Retention/Legs.hs`:

```haskell
data Leg = Leg
  { legName :: Text
  , run :: GateConfig -> (KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample]) }
allLegs :: [Leg]
```

Added by this plan to `keiro/retention/Retention/Fixture.hs`:

```haskell
type RetentionLedgerStream = EventStream (HsPred LedgerRegs LedgerCommand) LedgerRegs LedgerState LedgerCommand LedgerEvent
retentionLedger :: ValidatedEventStream (HsPred LedgerRegs LedgerCommand) LedgerRegs LedgerState LedgerCommand LedgerEvent
ledgerTarget :: Stream RetentionLedgerStream
seedLedger :: StoreRunner -> Stream RetentionLedgerStream -> Int -> IO ()
```

where `LedgerRegs`, `LedgerState`, `LedgerCommand` (`Deposit Int`), and `LedgerEvent`
(`Deposited Int`) mirror the test suite's snapshot counter aggregate, and `retentionLedger`
carries `snapshotPolicy = Every 100` and `stateCodec = Just (defaultStateCodec 1)`.

Added to `keiro/retention/Retention/Legs.hs`: `legCommandLongHistory`, `legHydrateOnly`,
`legKirokuReadTail`, `legCommandShortHistory`, `legCommandLongHistoryVerifyEvery :: Leg`,
appended to `allLegs` in that order.

Changed in `keiro/src/Keiro/Command.hs` (Milestone 4):

```haskell
data RunCommandOptions = RunCommandOptions
  { ...
  , seedVerifySampleRate :: !Int
  , seedVerifyInFlightLimit :: !Int   -- new; default 1; <= 0 means unbounded
  , ... }
```

Added to `keiro/src/Keiro/Telemetry.hs`: `keiroSnapshotSeedSkippedName`,
`keiroSnapshotSeedVerificationFailedName`, `recordSnapshotSeedSkipped`,
`recordSnapshotSeedVerificationFailed`, and the two `Counter Int64` fields in `KeiroMetrics`
wired in `newKeiroMetrics`.

Dependencies and why: `keiro-test-support` for the migrated ephemeral database;
`kiroku-store` for `appendToStream`, `readStreamForward`, and `lookupStreamId`; `keiki` and
`keiki-codec-json` for the ledger transducer and codec; `hs-opentelemetry-sdk` and
`hs-opentelemetry-exporter-in-memory` (already test dependencies) for the metric assertions;
`hspec`. Resolved versions in this workspace when the plan was written: kiroku-store
0.8.0.2, hasql 1.10.3.7, hasql-pool 1.4.2.3, streamly-core 0.3.1, effectful 2.6.1.0, keiki
0.9.1.0, GHC 9.12.4. The failing cohort used kiroku-store 0.8.0.1 and keiro 0.17.0.0; as in
plan 297, diff the kiroku tags for the read path
(`git diff kiroku-store-v0.8.0.1 kiroku-store-v0.8.0.2 -- kiroku-store/src/Kiroku/Store/Read.hs`)
before treating the harness as equivalent to the failing cohort, and record the result.


## Revision Notes


- 2026-09-24: after discussion, recorded three Decision Log entries on the verification bound
  in Milestone 4: keep the process-wide default limit of one with the options-field override
  and no caller-supplied gate type; defer same-seed deduplication (durable variant only, if
  ever) because an in-memory memo would be unbounded and the durable one is a schema and
  semantics change; add no replay timeout. No milestone, interface, or acceptance text
  changed, because the plan already matched the agreed design.

- 2026-09-25: recorded Kiroku BUG-3 as a strong candidate for the command-soak
  growth after verifying the soak appends without subscribers. Added a
  version-locked, single-change Kiroku comparison before assigning BUG-2
  ownership; kept the independent verification-bound milestone in scope.
