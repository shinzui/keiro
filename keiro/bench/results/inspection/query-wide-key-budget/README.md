# Wide workflow key population: bounded explicit failure

The actual library read runs at 10,000/100,000 rows whose workflow ids exceed
2600 encoded bytes. Existing primary keys accept these compressible values.
Owner name is wide; failed class is rare (0.1%). Both custom/generic plans
are retained. At 100,000 rows, default, deep, past-end, time-window and selected
wide-name reads inspect only 65 rows, then return InspectionWorkLimitExceeded.
The error occurs before a partial page is sent. Absent class/name and a
nonmatching small-name query inspect zero rows and return an empty page.

The exceptional population is budgeted before cursor/time filtering. A deep
cursor or an empty time window cannot make it search every large key. At most
64 matching class/name candidates and 256 KiB of combined keys are admitted;
the extra candidate is lookahead only. Oversized populations fail explicitly,
allowing clients to narrow class/name or use point header inspection.

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
