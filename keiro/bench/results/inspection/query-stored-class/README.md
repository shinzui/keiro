# Actual workflow pages with a stored class key

This prototype is rejected by the later [key-domain compatibility probe](../key-domain/README.md). The guarded successor is [query-guarded-keys](../query-guarded-keys/README.md). Fast access alone did not establish an acceptable schema.

These 60 plans execute the actual prepared statement installed by
listWorkflowInstancesPage, under force_custom_plan and force_generic_plan at
10,000/100,000 rows, normal planner settings, a 90% owner skew and many timestamp
ties. The four durable settings are asserted before each read. The manifest,
retained driver and source patch identify the candidate exactly.

At 100,000 rows the generic key-first/deep and mixed-class cases examine 22
workflow rows. Running and rare failed inspect 21, absent retrying/name inspect
zero, and the smaller-name page examines 31. A name-restricted rare-class page
examines 10, as does the entire eligible population; a deep rare page examines
20. Creation first/deep/window pages inspect 21 through migration 0033's index.
No sequence scan is disabled. Full buffers, sort memory, settings and timings
are in the raw plans; summary.json counts scan rows plus rows removed by filter
or recheck, multiplied by loops.

Migration 0034 adds a stored generated class and class/name/id index. Seven
fixed literal branches share one bound class mask and limit. The generic
planner can constrain each index branch without one SQL shape per class set.
Merging stops after the lookahead. No ordinary writer SQL, metadata encoding,
or event read is added; the schema has a measured storage/write cost. See the
rejected direct-expression and stored-class write experiments. This is a
candidate access-path result, not the complete 5% interference or write gate.

The automatic workflow-view contract permits key ordering with class/name
filters only; the feed child is not yet implemented.
Manual update windows still examine 100,000 rows; creation-order rare status
examines 20,001 under the generic planner. These shapes remain outside automatic
feeds. HTTP supplies the dedicated pool's 2-second statement timeout and the
5-second read budget; direct library users supply their own deadline policy.
A returned row cap never promises bounded search for those manual filters.

The generated-expression fingerprint uses JSON quoting, preserving one complete
catalog object per snapshot line, and records stored/virtual derivation. This
avoids discarding multiline CASE expressions during live comparison.
