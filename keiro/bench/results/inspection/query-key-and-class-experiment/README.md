# Ordered-key and class-index experiment

The actual supported library read installs each prepared statement before EXPLAIN. Two experimental indexes exist only on durable disposable 10,000/100,000-row clones: `(workflow_name,workflow_id)` and `(status-class expression,workflow_name,workflow_id)`. Normal planner settings and both forced plan-cache modes are retained. This selects no migration and establishes no index write-cost acceptance.

At 100,000 rows both key-order pages scan 21 rows through the key index, and an absent name scans zero. Creation pages still scan 21 through migration 0033's index. The custom plan for an absent retrying class uses the class index and scans zero; the generic plan instead scans all 100,000 rows through the key index. Generic rare failed status scans 21,000 rows to return 21. An absent updated-time window scans 100,000 rows under both modes. These are rejection evidence: more indexes alone do not fix the generic array-valued class predicate. Parameterized statement shape, supported automatic-feed filters and ordinary index write/HOT costs still require work.

The source hash identifies the experimental driver; the workflow library code remains at `d9960626`. Use the manifest command to reproduce. Raw JSON records SQL, bound EXECUTE arguments, rows, buffers, sort details and timings.
