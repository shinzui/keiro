# Diagnostic probe: benchmark-owned enumeration retention

These runs are diagnostic, not passing retention evidence. The pre-change
runtime retained approximately 40 B/operation after warm-up, just like idle
inspection. O1 Core floats the shared [1..sampleCount] list outside the complete
trial/mode callbacks (lvl255_srTm); it remains reachable for their future runs.
Each forced Int/cons pair costs 40 bytes. See shared-range-core.txt.

The benchmark now uses a strict recursive counter only in its heap-sampling
branch. Product runtime code and the previously frozen latency binaries are
unchanged. Corrected heap evidence is stored separately. The original raw
samples are retained to explain this measurement artifact.
