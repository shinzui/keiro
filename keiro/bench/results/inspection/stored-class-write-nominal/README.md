# Stored class prototype: storage diagnostic

Five alternating same-binary legs compare migration 0033 alone with a temporary
stored generated class column and class/name/id index. Baseline and candidate
use durable fresh 100,000-row clones; settings, full samples and counters are
retained. The generated expression partitions stored status/attempt/wake values
without new Haskell metadata encoding or ordinary database statements. Adding
the stored column rewrites the candidate clone and changes its physical layout;
this is part of the proposed schema and is not a controlled same-layout study.
No migration exists at this checkpoint. The exact driver is retained.

Normal schedule/claim/named-step/completion/release has 600 candidate HOT
updates versus 597 baseline, out of 800. WAL rises about 5.55% in every leg.
Paired p95 ranges from -14.0% to +9.35%; the median is -0.42%, but the short
runs and changing controls establish no 5% latency acceptance. Full allocation,
matched old/new binaries and active-inspection work remain necessary.

PostgreSQL's [generated-column documentation](https://www.postgresql.org/docs/18/ddl-generated-columns.html)
explains stored computation, and its [HOT documentation](https://www.postgresql.org/docs/18/storage-hot.html)
explains indexed-column and page-space eligibility. Their behavior is measured
here rather than inferred from a stable expression result.
