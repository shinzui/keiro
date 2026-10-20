# Creation index write-cost checkpoint

Five alternating same-binary legs compare a durable 100,000-row clone with migration 0033's creation index absent or present. Each warms 50 real schedule/claim/step/completion/lease-release operations, then measures 200 operations offered at 50 per second. Raw samples include scheduled queue delay. PostgreSQL settings, WAL positions, update/HOT counters, and phase durations are retained per leg. The manifest records build settings and source hashes.

The creation index adds about 41,800 WAL bytes per 200 operations (3.7%). Both legs record 800 updates and 597 HOT updates during each measurement interval. Paired p95 changes range from -12.0% to +7.4%; these short legs are preliminary and too noisy to establish the strict latency gate. Throughput is constrained by the offered rate. This does not compare pre-change/candidate runtime binaries, measure allocation, or establish active-inspection interference or retention acceptance.

Use the build and run commands in `manifest.json` to reproduce. Every database belongs to the disposable durable fixture; the baseline drops the index only on its own clone.
