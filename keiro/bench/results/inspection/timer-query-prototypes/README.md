# Pending-timer query preflight

These are M0 query prototypes, not final owning-API or write-cost acceptance.
The retained compiler input uses disposable durable benchmark databases and
normal PostgreSQL planner settings, both forced custom and generic prepared
plans, 10,000/100,000 rows, 90% hot owner skew, 25% fired rows, many equal due
times, four filter shapes, rare/absent filters and first/deep pages. Observed
durable/vacuum settings accompany every plan. Query parameter values stay
parameters even for rare and absent cases. Index stages are cumulative.

The existing index does not supply combined-status due/id order. A fixed-width
global partial index makes the unfiltered page an ordered range scan. Filtered
reads can still scan broadly; this experiment does not establish their feed
eligibility. The four-index set rejects correlation ids the previous writer
accepts (including 2670 and 10000 byte inputs). It cannot ship unchanged.
The global candidate preserves the tested key domain but remains unapproved
until real timer write/WAL/HOT evidence and actual owning-API plans are checked.
No production migration was created by this experiment.
