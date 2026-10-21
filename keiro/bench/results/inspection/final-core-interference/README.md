# Final core-path interference acceptance

Candidate 5893c7eb is compared with pre-change 3bf3ac22 using frozen binaries,
GHC 9.12.4/O1, identical dependencies, +RTS -N8 -A16m -T, fresh durable
100k workflow/timer fixtures, one writer connection and a separate inspection
pool. Writer schema/migration payloads match published 0.21.0.0 byte-for-byte.
Five baseline capacity legs qualify 100 operations/second below 75% of the
slowest observed capacity. Each of five blocks pairs all candidate modes with
one fresh baseline, alternating baseline-first/last and rotating candidate order.
No repository compilation or tests overlap; unrelated machine activity is
permitted by the user. Each measured leg runs for 20 seconds after warm-up.

| Mode | Writer throughput | Writer p95 latency | Writer-thread allocation / operation |
| --- | --- | --- | --- |
| disabled | +0.00% | -6.98% | -0.00% |
| idle | +0.00% | -0.25% | +0.00% |
| active-shared | -0.08% | -1.58% | +0.01% |
| active-distinct | -0.12% | -43.39% | +0.07% |
| slow-reader | -0.10% | -43.39% | +0.06% |
| churn | -0.12% | -13.01% | +0.02% |

All six paired medians satisfy the 5% core-path gate. Individual paired changes
and every per-operation sample are retained, including large timing variation.
These are local measured medians, not a universal zero-overhead or confidence
bound claim. The separate [five-pair capacity comparison](../readside-writer-capacity/README.md)
is also required: paced throughput alone concealed the rejected DDL prototype's
9.22% loss of writer headroom.

Modes cover unmounted, mounted idle, one shared view/client, 32 distinct views
with 256 clients, 32 slow-reader views/256 clients, and 32 churning views/clients.
Active modes include real workflow/timer/projection feed snapshots and repeated
HTTP polls through `/keiro`. Initial snapshots are required; missing client load
fails the run. Admission refusals are counted in JSON and client logs, including
HTTP 503 / inspection_busy under contention; finite admission protects the
writer. All mounted legs return zero views/connections and no wake pump.

The writer executes schedule/claim/resume/release workflow operations with a
real named step and completion, plus timer schedule/claim/fire. Core-thread
allocation uses GHC's approximate per-thread counters (about 4 KiB granularity).
Process CPU/allocation and database WAL/update counters are attribution data;
inspection latency and whole-process allocation have no blanket percentage gate.

`manifest.json` identifies both binaries and frozen source hashes;
`build-config.json` records optimization, explicit dependency selections, RTS,
pools and fixture settings. Source copies use `.txt` to preserve exact evidence.
[Final lifecycle probes](../readside-retention/README.md) and
[active cleanup](../readside-retention-active/README.md) provide separate heap
ownership evidence. Existing runtime behavior suites and hydration-specific
comparisons cover changed owner paths without a domain-outcome/UI-load cross-product.
