---
type: Bug Report
title: Operator schema verification flags Keiro's own external-read binding view as drift
description: "keiro-ops verifies the live keiro schema against a migrations-only snapshot, so the binding view Keiro creates for every all-rows external-read contract is reported as unexpected drift and every mutating operator command refuses without --allow-schema-drift."
generated:
  by: process:claude-code
  at: "2026-09-30T17:57:34Z"
bugId: BUG-9
status: reported
severity: degraded
origin: mori://tan/notification-render-service
affects: mori://shinzui/keiro
affectedVersion: "0.18.0.0"
environment: "Released keiro, keiro-ops and keiro-migrations 0.18.0.0 on PostgreSQL 18.6; a Language-6 service workspace with one all-rows external-read contract; keiro-ops mounted through AppHooks with the service's validated projection catalog. The snapshot and the check are unchanged at 0.19.0.0."
observed: "After the service registers its catalog and its group serves a compatible revision, every keiro-ops invocation prints \"schema drift: unexpected view keiro.external_read_catalog_status_v1_binding\", and every mutating command such as rebuild versioned resume is refused with \"refusing mutation because the live schema differs from this binary\" unless --allow-schema-drift is passed."
expected: "Objects that Keiro's own runtime creates inside the keiro schema are part of Keiro's schema. Schema verification should recognise the external_read_<function>_binding views it installs and report drift only for objects Keiro cannot account for, so operators are not trained to pass --allow-schema-drift routinely."
reproduction:
  - Declare one all-rows external-read contract in a Language-6 service (for example an `external-read catalog_status` node over a one-row target), validate and register the catalog with keiro 0.18.0.0, and establish versioned serving for its group so the contract reconciles; Keiro creates keiro_read.catalog_status_v1() and the view keiro.external_read_catalog_status_v1_binding.
  - Mount keiro-ops 0.18.0.0 with AppHooks { projectionCatalog = Just operations } and run a read-only command such as `ops rebuild list` against that database on PostgreSQL 18; the command succeeds but prints the drift warning naming the binding view.
  - Run any mutating command, for example `ops --force rebuild versioned resume <run-id>`; it exits with the refusal message. Repeat with `--allow-schema-drift`; it proceeds.
  - Remove the external-read declaration, register on a fresh database, and repeat; no warning is printed. The only difference is the all-rows contract.
workaround: "Run the read-only form of the command first and confirm that the binding view is the only reported drift; only then pass --allow-schema-drift to the mutating command. Keyed external-read contracts create no binding view and do not trigger the warning."
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-09-30T17:57:34Z"
    document_timestamp: "2026-09-30T17:57:34Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-fable-5-1
    effort: unspecified
    context: Observed through the consumer's mounted operations console on a PostgreSQL 18 test cluster, traced the view creation and the snapshot comparison in the pinned 0.18.0.0 release source, confirmed the snapshot is unchanged at 0.19.0.0, and validated against the pinned bug-report profile. This is the reporter's evidence check, not independent owner confirmation.
---

# Operator schema verification flags Keiro's own external-read binding view as drift

The notification-render-service exposed this while implementing ExecPlan 6 under
MasterPlan 1, when its operations console (keiro-ops mounted as a subcommand of the
projection worker) was first exercised end to end on PostgreSQL 18. The service
declares one all-rows external-read contract, `catalog_status` v1, which the render
kernel's readiness probe calls. This report records the defect; it does not include
a patch.

## Observed behaviour

With the catalog registered and the `catalog_views` group serving its v1 revision,
every keiro-ops invocation begins:

```text
warning: schema drift: unexpected view keiro.external_read_catalog_status_v1_binding (actual: columns=1:sequence integer,2:digest text,3:build_id text)
```

Read-only commands (`rebuild list`, `rebuild preview`, `rebuild versioned status`,
`rebuild external-read`) then run normally. Every mutating command stops:

```text
keiro-ops: refusing mutation because the live schema differs from this binary; inspect the warnings or pass --allow-schema-drift
```

With `--allow-schema-drift` the same command succeeds. The consumer's worker test
suite drives `rebuild versioned resume` and `rebuild versioned abandon` this way and
observes both the refusal and the success.

## Source explanation

The 0.18.0.0 cohort is pinned by tags `keiro-0.18.0.0`, `keiro-ops-0.18.0.0` and
`keiro-migrations-0.18.0.0` at commit `b12bbdd7abc8c1a59e7a09891471ef182a4d801a`.

- [External.bindingViewName and bindingViewSql](https://github.com/shinzui/keiro/blob/keiro-0.18.0.0/keiro/src/Keiro/ReadModel/External.hs#L474-L489)
  create `keiro.external_read_<function>_binding` with `CREATE OR REPLACE VIEW` for
  every contract that has a binding table. [toSpec](https://github.com/shinzui/keiro/blob/keiro-0.18.0.0/keiro/src/Keiro/ReadModel/External.hs#L412-L421)
  supplies that table only for `InventoryAllRowsExternalRead`; keyed contracts get
  `Nothing` and no view. The statement runs during contract reconciliation
  ([External.hs#L294](https://github.com/shinzui/keiro/blob/keiro-0.18.0.0/keiro/src/Keiro/ReadModel/External.hs#L294)),
  which is a runtime operation, not a migration.
- [SchemaCheck.snapshotSchema](https://github.com/shinzui/keiro/blob/keiro-0.18.0.0/keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs#L106)
  lists tables (`relkind = 'r'`), columns, constraints, indexes and views
  (`relkind = 'v'`) of the `keiro` and `keiro_read` schemas. Functions are not
  snapshotted, which is why the `keiro_read.*_v1` wrapper functions created by the
  same reconciliation are not reported while the view is.
- The expected snapshot
  [expected-schema/native/keiro-v18.txt](https://github.com/shinzui/keiro/blob/keiro-0.18.0.0/keiro-migrations/expected-schema/native/keiro-v18.txt)
  holds 25 tables and one view and no `external_read_*_binding` entry; it is
  generated from the migrations alone. The file is unchanged at
  `keiro-migrations-0.19.0.0`.
- [Ops.runInvocation](https://github.com/shinzui/keiro/blob/keiro-ops-0.18.0.0/keiro-ops/src/Keiro/Ops.hs#L146-L156)
  calls `verifyExpectedSchema`, prints every drift as a warning, and refuses any
  command for which `isMutation` holds unless `allowSchemaDrift` is set.

The verification therefore compares the live schema against an incomplete
definition of Keiro's own schema: it knows the objects Keiro's migrations create but
not the objects Keiro's runtime creates for a registered catalog. Any service that
declares an all-rows external-read contract, which is the documented way to expose a
small projection to an outside reader, trips the check on every mutating operator
command for the life of the deployment.

## Existing contract and scope

`keiro-ops` documents `--allow-schema-drift` as an escape hatch for a schema the
binary was not built for. Making it necessary for every mutation on a correctly
deployed service defeats the check: operators learn to pass the flag, and a genuine
drift hides behind the expected warning. This is wrong behaviour in an existing
capability and belongs in the bug-report profile.

A fix should have schema verification account for the objects Keiro's runtime
manages, either by recognising the `external_read_%_binding` naming pattern (and
any other runtime-managed object) as expected in `compareSchemaSnapshot`, or by
having `snapshotSchema` exclude them. Regression coverage should register a catalog
with one all-rows contract on a fresh database, reconcile it, run
`verifyExpectedSchema`, and expect no drift, while a genuinely foreign view in the
`keiro` schema is still reported.

Out of scope here: `verifyExpectedSchema` also refuses every PostgreSQL major other
than 18 (`UnsupportedPostgresVersion`), which is a separate limitation and not
asserted as a defect by this report. No last-working release is asserted.

Status remains `reported`: the consumer observed the behaviour on a real cluster
and traced its cause, while the owning repository has not independently confirmed
or fixed it.
