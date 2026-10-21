# Final read-side ownership probes

Candidate 5893c7eb uses the published writer schema, strict server connection
registry updates, and the strict heap-probe counter. These 60-second probes
run at 100 ordinary workflow/timer operations per second over the same 100k-row
ledgers. They sample post-major heap every 500 operations, detach all clients,
wait for view/connection/wake-pump ownership to reach zero, drain timeout
bookkeeping for 12 seconds, then take the cleanup sample. The companion
[active probe](../readside-retention-active/README.md) uses the same binary.
Repository verification overlapped these ownership probes, so timing and poll
admission failures are diagnostic, not latency acceptance. Saturated admission
is allowed to refuse inspection work; errors are counted in the raw rows.

| Profile | Views / clients | Live heap after cleanup | Active threads after cleanup |
| --- | --- | --- | --- |
| Idle mount under writer notifications | 0 / 0 | 902,256 bytes | 17 |
| Slow readers | 32 / 256 | 1,669,584 bytes | 18 |
| Subscription churn | 32 / 32 | 1,610,720 bytes | 17 |

All three return zero views/connections and no wake pump; starting active-thread
counts are 18. Idle heap levels near 3.08 MB after warm-up; slow-reader heap levels
near 38.9 MB while socket buffers are retained by live clients. Churn remains
bounded through repeated replacement. Cleanup retains the mounted server and
bounded presentation/schema caches. These finite probes support lifecycle
acceptance within the tested envelope; they are not a universal leak-freedom claim.

Binary hashes and build settings are recorded in `manifest.json`; frozen driver
sources are shared with [capacity evidence](../readside-writer-capacity/README.md).
The old enumeration-retaining and lazy-registry probes are preserved separately
and explicitly superseded. No blanket process-allocation or inspection-latency
percentage target is inferred from these samples.
