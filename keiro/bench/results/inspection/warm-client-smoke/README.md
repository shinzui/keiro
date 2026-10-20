# Controlled-client smoke test

A single 32-view real-socket leg validates the warmed-client control protocol: all 640 measured polls succeed and client processes and connections close cleanly. It is a functional smoke test, not performance acceptance. The final driver adds the same settling period and aligns PostgreSQL counters in every mode before the matched run.
