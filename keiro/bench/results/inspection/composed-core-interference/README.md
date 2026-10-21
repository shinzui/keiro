# Superseded paced inspection measurements

These low-load medians do not establish final core-path acceptance. A later
matched saturation check found about 9% writer capacity loss from the
inspection-only schema additions. Those additions are withdrawn; see
../composed-writer-capacity-final/. Raw samples remain diagnostic.


Candidate `8b8785c97d94f369e1c3e163ea1ccf2683ec4654` versus pre-change
`3bf3ac229f21d6c95179ce49b5e8f6323322f99b`, built independently in the Nix
shell. Every one of the baseline's 295 external build IDs is preserved in the
candidate plan. Library and driver optimization are O1, GHC 9.12.4,
`+RTS -N8 -A16m -T`. See `build-config.json` and the immutable source copies.
No compiler or repository test run overlapped these measurement legs. Other
machine activity was permitted, following the user's direction.

Five baseline saturation runs measured 726.84–737.68 operations/second. The
fixed offered rate was 100/s for 20 seconds per measured leg. Five fresh-process
blocks alternate baseline-first/baseline-last and rotate candidate order. Each
mode is paired with its block's baseline; controls are shared within that block.
This is a measured fixture envelope, not a universal latency promise.

| Candidate mode | Throughput | Core p95 | Writer-thread bytes/operation |
|---|---:|---:|---:|
| disabled | -0.004% | +1.978% | -0.001% |
| idle | -0.011% | +2.272% | -0.001% |
| active-shared | -0.112% | +1.493% | +0.014% |
| active-distinct | -0.173% | -42.839% | +0.079% |
| slow-reader | -0.142% | -41.583% | +0.064% |
| churn | -0.128% | -13.687% | +0.022% |

All five-pair median comparisons meet the 5% core gates. Individual samples
remain in each JSON file and paired changes are retained in `summary.json`;
there is no claim that every individual timing is within 5%. The unmounted
pair changes range from roughly +1.85% to +13.50%, so the observed median is
not a confidence bound. The active large-view measurements have lower p95 in
this fixture; that is not a general claim that inspection improves runtime.

Each completed operation schedules/claims/resumes/releases a workflow and
schedules/claims/fires a timer through supported APIs. The SQL fixture seeds
100k workflows and a 100k mixed-lifecycle future timer ledger before warm-up,
including 64 KiB fields. Future seed timers cannot be claimed by the writer.
Five settings checks require fsync, synchronous_commit, full_page_writes and
autovacuum on; raw settings and WAL/table-update counters are in every leg.
The runtime writer uses one reserved connection; inspection has four separate
connections with two-second SQL deadlines and its existing shared admission.

Active shared uses one client/view. Active distinct and slow-reader use 256
clients sharing 32 canonical views (30 workflow, one timer, one projection).
Churn uses 32 clients/views. Clients also poll 32 exact workflow headers; those
presentations are primed before timing. All traffic goes through `/keiro`.
Client allocation is outside the measured runtime process. Bounded admission
and feed refusals are recorded by code in per-leg logs, rather than guessed
from aggregate error counts. Every mounted leg joins its load process and
asserts zero driver views, connections and wake pump before returning.

`writer_thread_allocated_bytes_per_operation` attributes the calling runtime
thread with GHC's approximate allocation counter (about 4 KiB precision).
Whole-process allocation, CPU and WAL are diagnostics; dividing UI allocation
by writer completions does not establish a core-path regression. Ordinary
hydration's separate five-pair evidence and the default-off provenance/source
and behavior checks supply the other changed core-path proofs. This harness
does not claim a cross-product of every unchanged domain decision and UI mode.

Reproduce inside the Nix shell with independently compiled baseline/candidate
binaries using the retained source and package IDs:

```bash
nix develop -c python3 scripts/inspection-composed-evidence.py BASELINE CANDIDATE NEW_OUTPUT
```

The public benchmark target is `keiro-ops-http:bench:inspection-interference`;
use `--mode disabled|idle|active-shared|active-distinct|slow-reader|churn`,
`--output`, `--rate` and `--trials`. For isolated heap samples set
`KEIRO_INSPECTION_RETENTION_SECONDS=60` (or longer). Retention evidence is kept
separately so forced collections do not contaminate these latency samples.
