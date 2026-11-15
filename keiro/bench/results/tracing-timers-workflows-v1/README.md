# Timer and workflow tracing evidence

Runtime/benchmark candidate: `412721f4`; control: accepted EP-4 `d4af0034` in a detached
worktree, with `control-measurement-harness.patch` applied. Dependency versions match exactly
(`source.json`). Binary and harness hashes are retained there. Machine, compiler and RTS
context reuse `../tracing-baseline-v1/environment.json`: Apple Silicon, GHC 9.12.4,
PostgreSQL 18.6. The fixture uses disposable local PostgreSQL with fsync, synchronous commit
and full-page writes enabled; no remote benchmark override was present.

`samples/` contains five serial samples per binary, alternating which binary runs first in
each pair. No compiler, test suite or other benchmark ran alongside these recordings. Each
run uses the binary directly inside Nix:

```bash
nix develop -c /absolute/path/to/keiro-bench \
  -p '/durable-tracing/' -j1 --time-mode wall --stdev 5 --timeout 10s \
  --csv /absolute/output.csv +RTS -N2 -T -RTS
```

`control-median.csv` and `candidate-median.csv` take each column's median across the five
samples. Their time field is the median of the five Tasty means; their deviation field is
merely the median of Tasty's within-run deviations, not a confidence interval for that
aggregate. Every control timing is within 8.3% of its own median. Raw files remain authoritative.
`comparison.md` reports the matched medians and allocation differences.

## Fixed work and costs

Each timer invocation resets its table, schedules exactly 100 requests in one transaction,
and drains exactly 100 fires. Traced scheduling runs inside one live creation span and captures
per request; each fire opens its own root/link. Default trace state is absent. The table never
grows beyond those 100 rows. No-tracer allocation adds 3,872 bytes per schedule/fire pair for
the new request/row slots and nullable SQL parameters/columns. The original fire/mark path is
selected directly. Traced allocation adds 20,181 bytes per pair versus control, including that
schema cost, context capture, link decoding and the new span/attributes.

Each workflow invocation performs ten resumes against a fixed workflow and snapshot of either
1 or 1,000 journal steps. Setup journals the prefix and wake, writes a snapshot beyond both,
and analyzes the seeded relations before warming either binary. Each timed resume prepares
the same exact wake hint under the real step lock, replays the origin/wake, then parks on a
second unresolved wait. Both suspension writes are included. There is no timed journal growth;
journal stamping is exercised in setup and the behavior tests, while this cell isolates resume
cost. The additional nullable hint parameter and entry bookkeeping add about 0.8–1.1 KB per
untraced resume (under 0.4% of allocation). Traced resumes add about 99–100 KB per resume for
bounded reference/hint discovery, two normal event reads and evaluated links/context scope.

The observed added traced-resume time is 0.121 ms at one step and 0.119 ms at 1,000 steps.
That is +27.85% and +13.67% respectively: the additional work does not scan the journal.
No-tracer timing changes are +1.77%, +2.68% and +7.63%; traced timer timing is +0.61%.
These are explicitly attributed feature costs under EP-6's reading rule. An exploratory 25%
comparison refuses the short traced-resume cell; its raw refusing receipts are retained.
No historical baseline, numerical release guard or guard selection was changed. These new
cells are measurement evidence, not a newly installed percentage release guard.

## Rejected approaches retained

The first implementation called the generic one-event forward read for origin recovery.
EXPLAIN shows a sort/join over all 1,001 events before LIMIT. A focused unchanged-source
recheck reproduced the long-snapshot slowdown. ANALYZE alone still left that scan/sort.
`origin-plan-diagnostic.log.gz` and the initial CSV/log files preserve this evidence.

Generic query source: [kiroku-store](mori://shinzui/kiroku/packages/kiroku-store),
`src/Kiroku/Store/SQL.hs` (source artifact URI pending).

The accepted implementation selects an indexed first-event reference with a limited lateral
read alongside the generation-qualified hint, sharing the existing generation transaction.
It fetches origin and exact wake through `getEvent`, retaining configured read hooks and
validating source stream, version and decoded awaited step. This bounds the evidence reads
independently of snapshots. Intermediate indexed/read-transaction receipts remain separate;
they are not silently substituted for the five final sample pairs.

## Behavior, ownership and integration

- Migration 0033 passes all 42 migration cases, including legacy-row upgrade with null trace
  fields. Before runtime changes, old timer code passed 27 cases against the additive schema.
- All 28 timer cases pass, including actual command scheduling, root fire linking, dispatched
  command parenting and event stamping. Six durable scenarios cover the real Kiroku command /
  subscription reaction / timer / workflow chain, snapshot-independent exact attribution,
  unrelated later events, failure restoration/retry, signal idempotence, child completion,
  rotation, wake-before-suspend, missing and malformed/foreign/mismatched evidence.
- Full `just verify` passed at `3bc78fab`: 828 core, 898 DSL, 30 retention, 83 PGMQ (two existing
  pending), 61 ops, HTTP/example suites, all mutation proofs, migrations and strict policies.
  `full-verify-3bc78fab.log.gz` is the uninterrupted successful receipt.
- The small review refinement at `412721f4` passes all six durable cases, all 28 timer cases,
  and ten focused retention/ownership cases. Those original logs are retained. The two
  1,500-operation legs end Bounded: timer 566 B/op, 0.54 MiB; workflow 1,122 B/op, 1.07 MiB.
- The final ownership probe additionally fetches distinct origin and wake rows, forces their
  actual payload objects before weak references, and keeps 32 exported spans reachable while
  all three payloads per iteration collect. All eight ownership cases pass, including the
  existing live-span and span-owned negative controls. Its test-only patch and receipt are
  retained separately from the measured runtime source.
- `jitsurei tracing` exported ten spans in six traces to the local VictoriaTraces backend.
  `backend-proof.json` checks command → linked processing → child packing command → linked
  root send, and processing → root timer → root workflow with exact wake and origin links.
  The full backend payload and demo output are retained. The outbox uses a transport success
  stub; the spans use the real SDK/exporter. Source-stream global position zero is resolved
  with a global event read before applying the producer cutoff. SDK endpoint prefixes and
  inherited exporter headers are documented in Operations.
- Current-version release preflight passes, including strict docs, all eight package checks,
  publication/dependency checks, blueprint checks and corpus verification. This is not a
  0.25.0.0 publication/readiness claim. Version approval and the final release workflow remain
  an initiative gate.
