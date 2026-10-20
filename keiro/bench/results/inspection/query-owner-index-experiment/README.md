# Actual owner detail pages: matching-index experiment

These 48 plans execute prepared statements installed by the supported
listWorkflowChildrenPage and listWorkflowAwakeablesPage APIs. Each fixture has
10,000 or 100,000 rows for one owner plus 10% additional rows for a second owner,
with many equal creation timestamps. First, deep and absent-owner pages run
under both custom and generic plans with normal planner settings.

At 100,000 rows per owner the generic baseline first and absent-owner queries
scan all 110,000 rows. Deep queries read 100,000 owner rows and filter/sort.
The existing owner-only indexes do not bound a page's search and sorting.
Temporary matching indexes constrain owner and creation/tie keys: present first
and deep pages examine 21 rows; absent pages examine zero, under both planner
modes. All full plans, buffers and sorts remain alongside the derived summary.

The candidate indexes are only on these disposable clones. No owner-index
migration exists at this checkpoint. The companion owner-index-write experiment
must inform selection; query speed alone is not acceptance. These plan timings
are diagnostic and do not establish the 5% latency gate. The fixture helper
supplies normal durable settings, but this driver does not separately record a
per-page settings assertion. The manifest states that limit explicitly.

The facade performs one observation-clock session and one row-page session.
The EXPLAIN target is the actual row statement, selected from the connection's
prepared statements after one supported read. It does not reproduce private
owner SQL in the harness. Driver/binary hashes and a parent-relative compressed
production source patch identify the executed candidate.
