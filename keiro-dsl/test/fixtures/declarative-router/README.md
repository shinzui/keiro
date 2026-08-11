# Declarative Router Fixtures

`valid.keiro` is the candidate Language 5 source-of-truth fixture for checked,
bounded router selection. It exercises a mapped query input and row, a typed
predicate and recipient path, total command mapping, every required policy, and
a positive post-deduplication recipient cap.

`unbounded.keiro` is the single-purpose negative twin. It intentionally omits
`max-recipients` and must fail check with
`RouterSelectionRecipientLimitMissing`. Keep the files otherwise aligned so
that the refusal remains attributable to boundedness rather than unrelated
syntax or type drift.

The PostgreSQL-backed generated behavior proof lives in
[`../../conformance-declarative-router/README.md`](../../conformance-declarative-router/README.md).
