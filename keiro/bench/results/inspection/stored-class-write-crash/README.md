# Stored class prototype: storage diagnostic

Five alternating same-binary legs compare migration 0033 alone with a temporary
stored generated class column and class/name/id index. Baseline and candidate
use durable fresh 100,000-row clones; settings, full samples and counters are
retained. The generated expression partitions stored status/attempt/wake values
without new Haskell metadata encoding or ordinary database statements. Adding
the stored column rewrites the candidate clone and changes its physical layout;
this is part of the proposed schema and is not a controlled same-layout study.
No migration exists at this checkpoint. The exact driver is retained.

Repeated public recordCrashTx plus a public attempt reset every twenty crashes
has 190/210 HOT updates, versus 210/210 baseline. Only the twenty transitions
between running and retrying require non-HOT writes; repeated retry increments
retain HOT. WAL in these fresh-clone legs is about 42.7 KB versus 46.9 KB, about
9% lower. Physical rewrite/layout differences preclude attributing the reduction
to a single mechanism or generalizing it to complete worker workloads.

The direct expression-index companion loses all 210 HOT updates and adds about
190% WAL. This stored projection is a candidate to investigate with the actual
inspection API, not a complete read/write or cohort acceptance result.

PostgreSQL's [generated-column documentation](https://www.postgresql.org/docs/18/ddl-generated-columns.html)
explains stored computation, and its [HOT documentation](https://www.postgresql.org/docs/18/storage-hot.html)
explains indexed-column and page-space eligibility. Their behavior is measured
here rather than inferred from a stable expression result.
