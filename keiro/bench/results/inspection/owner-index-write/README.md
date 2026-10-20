# Added owner indexes: not accepted

Five short alternating same-binary legs add matching child and awakeable page
indexes while retaining the existing owner-only indexes. All four durable
settings are asserted and recorded. Each fresh fixture has 100,000 rows in each
of workflows, children and awakeables. Fifty operations warm each leg before
200 measured operations at 50/s, with RTS -N2 -T and before/after major GCs.

The workflow schedules, claims, runs a named step and completes/releases. The
step calls exported child/awakeable registration and completion transaction
primitives. This measures real storage writes, not complete spawned-child workers
or external signal delivery. The full cohort/domain gate still needs those paths.

WAL rises about 8.51% in every pair. HOT counts are unchanged: workflow 600/800,
child 0/200 and awakeable 0/200 (existing status indexes already preclude HOT on
their completion). Allocation changes +0.09% to +0.26%. Paired p95 changes are
+3.77%, +11.37%, +12.22%, +6.72%, and -1.13%; median +6.72% exceeds the 5% gate.
These short runs are not proof of an acceptable regression. No owner-page index
migration is selected. Replacing redundant prefix indexes and preserving the
valid key-size domain must be assessed before any production index choice.

Raw queue/schedule/claim/resume samples, table counters, settings and allocations
are retained. The manifest, retained driver and compressed parent-relative source
patch identify the candidate; PostgreSQL plan timings are not inferred from this
writer experiment.
