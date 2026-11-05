# Original candidate: measured burst-latency failure

This run continued on the available machine as explicitly directed by the user.
Ambient processes were recorded as diagnostics and did not reject a leg.
The unchanged baseline and original candidate completed five alternating capacity
pairs, followed by paced blocks at 80 writer operations/second on one million
balanced-class workflow headers. The parent and external HTTP clients used the
actual application, default four-slot admission and existing deadlines.

Capacity paired medians were +9.836% throughput, -10.151% p95 latency and +0.005%
writer-thread allocation. The original candidate's eight-client count bursts,
however, increased writer p95 against their mounted-idle controls by 593.72%,
35.44% and 12.77% in the first three complete blocks. All three exceed the
existing 5% ceiling, so even the remaining two blocks could not make the planned
five-block median pass. `failure-summary.json` retains those measured values.
Single-client polls completed all 20 requests per measured leg. Each eight-client
leg completed 80 successful count reads and 80 admission refusals, with successful
post-burst recovery; this was real work, not an all-refusal experiment.

The controller was interrupted after the failure became decisive; no successful
performance acceptance is claimed. Raw samples, complete commands, settings,
writer allocation, WAL/update counters, poll outcomes and binary/source hashes
remain in the artifacts and manifest. The owned process group was cancelled with
cleanup. Unrelated processes were left running.

The minimal candidate fix sets `max_parallel_workers_per_gather=0` only on
connections created by the dedicated inspection-pool helper. Four requests may
still be admitted, but each query uses one PostgreSQL backend instead of creating
a parallel worker group. Statement/handler deadlines, the schema and ordinary
writer connections are unchanged. All 58 HTTP tests passed after the change,
including the pool setting, statement cancellation and resource recovery.
`runtime-serial/` contains the final-candidate rerun when complete.

The original frozen candidate and its source patch are preserved in
`../binaries/candidate-v1.json`; the updated candidate has its own binary/hash.
Rebuilds use the retained baseline dependency constraints to preserve the exact
shared dependency unit identities, rather than accidentally upgrading packages
when a local Hackage index changes during a long experiment.
