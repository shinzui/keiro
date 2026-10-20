# Independent view/client smoke: allocation target exceeded

One alternating pre-change/candidate workflow-writer trial at the previously
qualified 380 operations/s uses fresh durable 100,000-row fixtures and RTS
-N2 -T. Every leg satisfies the declared writer headroom check. This is a
single-run diagnostic, not the five-run acceptance gate.

Unmounted and idle candidate allocation changes are -0.02% and -0.01%.
One client polling 32 views completes 640 requests, with allocation +1.43%.
256 clients sharing one view or 32 views each complete 5,120 requests, without
errors, but allocation rises +11.55% and +11.54%. Their writer p95 changes are
-1.89% and -1.12%; those single observations establish no latency acceptance.
The allocation result motivates attribution and optimization before repetition.

The writer operation, seed, fixed load, optimization, RTS settings and common
dependency units match across binaries. The manifest identifies both commits
and binary/source hashes. Retained driver, client and runner sources reproduce
the probe; raw legs preserve every schedule/claim/resume sample and database
setting. The runner deliberately retains all legs even if a smoke check fails.

This excludes the complete domain, large-value, slow-reader and strict
retention matrix. No child-plan or cohort acceptance follows from this probe.
