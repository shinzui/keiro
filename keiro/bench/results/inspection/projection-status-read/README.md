# Projection-status page query evidence

Both artifacts retain the actual Hasql prepared SQL and EXPLAIN ANALYZE,
BUFFERS and SETTINGS under custom/generic planning on durable disposable
10k/100k-group fixtures. There are three models per group and 10,000 additional
models in the first group. No index or writer change is installed.

LIMIT over the frozen view processed the fleet before sorting: the 100k generic
first/deep samples took 199.583/166.443 ms. Selecting a bounded page of Keiro-owned
group keys first and retaining correlated lookups through the same frozen v1
relation took 2.779/0.562 ms. At 10k the corresponding samples were 2.736/0.495 ms.
The explicit OFFSET 0 boundary retains the parameterized per-key lookup. The v1
relation and its decoder remain unchanged, as does the compatibility listing.

These are query-work diagnostics, not a blanket inspection latency target or
writer-interference pass. Each selected group's model/checkpoint cardinality and
encoded body still matter; the read/encoding deadline and byte caps remain
required. The retained driver is formatted source for the same fixture and calls; the earlier
artifact records the earlier exact SQL/arguments on the same fixture design.
The actual prepared SQL, parameters and settings in each artifact are the
execution record; formatting of the retained source followed compilation.
