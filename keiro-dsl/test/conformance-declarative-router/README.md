# Declarative Router Conformance

This candidate Language 5 conformance service is scaffolded from
[`../fixtures/declarative-router/valid.keiro`](../fixtures/declarative-router/valid.keiro).
Its generated module inventory and selection snapshot are tracked by the Cabal
fragment and ledger in this directory.

The executable owns a real PostgreSQL proof of the generated boundary. The
application query deliberately returns `B,A,A`; generated normalization
dispatches `A,B`. After the rows drift to `B,C`, redelivery confirms `B` as a
duplicate and appends only `C`. A second selection maps unequal commands to one
physical stream and proves that conflict detection writes nothing.

Run it from the repository root with:

```bash
cabal test keiro-dsl-conformance-declarative-router
```

Do not edit scaffold-owned generated modules to change behavior. Update the
fixture and regenerate through the normal scaffold/conformance workflow;
create-once read-model binding and query implementations remain
application-owned.
