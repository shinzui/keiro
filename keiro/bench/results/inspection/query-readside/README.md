# Read-side workflow query plans

68 EXPLAIN (ANALYZE, BUFFERS) captures execute the actual supported prepared
inspection reads against 10k/100k ledgers under forced custom/generic plans.
Classification reads ordinary status/attempt/wake fields. Only the published
writer schema and its existing key/status indexes are present: inspection adds
no column, index or migration payload. Existing wide-key/read budgets and
cursor contracts are retained.

Raw SQL, parameters, settings, indexes and plans are in every JSON file.
Observed execution times range from 0.046 to 26.879 ms; the slowest is the
100k creation-order first page (scan/sort). These captures overlapped repository
verification and establish query shape/cost diagnostics, not the core writer
interference gate or a universal latency bound. Hosts retain SQL deadlines and
shared inspection admission; creation/update-window reads remain manual.

The matching driver is scripts/inspection-query-evidence.hs, frozen here as
source text. The writer schema/migration bundle is byte-identical to the
published 0.21.0.0 payloads. The previously retained guarded/stored-class index
plans are rejected prototypes after their roughly 9% writer-capacity regression.

2026-10-25: [v2 query evidence](../query-readside-v2/README.md) replaces the
obsolete narrow/wide query for current inspection pages. These historical plans
remain evidence of the old contract and are not current performance acceptance.
