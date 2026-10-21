# Writer capacity with read-side inspection

Five alternating baseline/candidate saturation pairs use GHC 9.12.4, O1 and
`+RTS -N8 -A16m -T`, fresh durable 100k workflow/timer fixtures, and one writer
connection. Inspection is unmounted. The baseline is pre-change 3bf3ac22 and
the candidate is 5893c7eb with read-side classes and the exact published 0.21.0.0
writer schema/migration bundle. No writer column/index is added for inspection.
The same 295 baseline external build IDs are preserved. No repository compiler
or test overlapped these legs; other machine activity remained permitted.

Median paired changes: throughput -1.664%, p95 -1.702%, writer-thread bytes per
operation -0.010%. All meet the 5% core gates; raw paired variation is retained
in summary.json, without a universal zero-cost or confidence-bound claim.
The former stored-class/index strategy lost about 9.22% writer capacity and is
withdrawn (../composed-writer-capacity-final/). Paced throughput alone had hidden
that headroom loss. Each operation drives workflow schedule/claim/resume/release
and timer schedule/claim/fire through the same APIs in both package sets.

Every leg exports durability settings, WAL/table counters, CPU, allocation and
individual timings. Full frozen source and binary hashes accompany this evidence.
Active-inspection interference and lifecycle measurements are separate gates.
