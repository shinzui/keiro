# Matched workflow header checkpoint

Five alternating pre-change and candidate trials use the same writer source, GHC 9.12.4, driver `-O2`, library `-O1`, RTS `-N2 -T`, and identical common dependency units. Each deployment mode uses a fresh durable server/database, 100,000 seeded workflow rows, 50 warm writer operations, and 7,600 measured operations at 380 per second. All five old-runtime baseline legs pass the declared headroom check. The pre-change checkout is commit `3bf3ac229f21d6c95179ce49b5e8f6323322f99b`; the candidate is `d9960626` plus `source.patch.gz`. Pins, source/binary hashes, commands, raw queue/schedule/claim/resume samples and execution order are retained.

The initial offered rate was 75% of the minimum of five old-runtime burst capacities, rounded down to ten (480/s). Paced qualification rejects that rate and accepts 380/s after the predeclared 20% reduction. Rejected qualifications remain under `paced-qualification/`. Clients run outside the runtime process and every active leg serves exactly 20 or 640 successful polls with no failures.

| Candidate mode | Median throughput change | Median writer p95 change | Median allocated-byte change |
|---|---:|---:|---:|
| Unmounted | approximately 0% | +0.10% | -0.05% |
| Mounted idle | approximately 0% | +0.84% | -0.16% |
| One view | -0.18% | +0.18% | -0.11% |
| 32 views | -0.19% | -0.90% | +1.52% |

The medians are within 5% for this narrow profile. Latency is **inconclusive**, not an accepted gate: control changes vary substantially and the first 32-view leg has a 291 ms p95 queue-delay spike. Writers and schema verification are warmed, but active client connections and per-view parsing are cold at measurement start. Retain these as startup evidence; a separately warmed-client steady-state comparison is required. This does not cover all domain workloads, large values, slow readers or retention, and does not complete EP-1/EP-2.

Run the build flags in `source-manifest.json` against the two package sets, then invoke the retained runner from the repository root with baseline binary, candidate binary, pre-change capacity directory and output directory. `comparisons.json` retains all five paired changes; no outlier is discarded.
