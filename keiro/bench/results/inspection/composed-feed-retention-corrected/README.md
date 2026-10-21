# Intermediate heap probes before connection-registry cleanup

These probes fix the shared-enumeration artifact and demonstrate a flat
pre-change baseline and idle handle. They predate the strict connection map
fix and still include the withdrawn writer DDL. Loaded cases returned zero
active views/connections/wake pump and initial active-thread counts, yet held
about 10.6 MB after cleanup. The server's lazy MVar insert/delete chain retained
completed Async handles and buffers until shutdown. Commit 88b56fc1 forces the
updates; final read-side evidence measures the corrected runner and schema.

The active repeat and 120-second slow-reader leg preserve the investigation;
they are not final acceptance or evidence that logical zero counts alone prove
memory cleanup. See ADR-48 and the later readside-retention evidence.
