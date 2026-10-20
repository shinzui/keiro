# Guarded workflow index plans: normal keys plus exceptions

The actual library read runs at 10,000/100,000 normal rows plus two near-limit
incompressible keys, with 90% owner skew and equal timestamp groups. Both custom
and generic plans are retained. At 100,000 rows generic first/deep key pages
examine 24 rows including both exceptions; rare failed examines 22, absent class
or name zero, and small-name 31. Creation first/window examine 21 and deep 23.
A page filtered to the wide-key owner examines only those two records.

Manual update-window filtering still examines 100,002 rows; creation-order
rare-status examines 19,002 under the generic planner. Those shapes remain
outside automatic feeds and use host SQL/read deadlines. The automatic
key/class/name workload is the bounded access-path result established here.

All 68 raw EXPLAIN (ANALYZE,BUFFERS,SETTINGS) outputs execute prepared statements
installed by listWorkflowInstancesPage. No sequential-scan planner switch is
used. Each record contains the asserted durable/autovacuum settings and server
version. The summary counts scan rows plus rows removed by filter/recheck,
multiplied by loops; raw plans retain all buffers, sorts and timings.

The unreleased creation/class indexes exclude wide tuples. A fixed-width
class/name-hash/id-hash index preserves their ordinary writer key domain;
exact text rechecks preserve equality. The read merges a bounded exceptional
set in the same statement and preserves database ordering/cursor contents.
The retained driver, binary/source hashes and compressed parent-relative patch
identify this candidate. These are query-cost/functional results, not the
complete 5% write/interference or retention gate.
