---
type: Reference
title: Keiro DSL Queues and Read Models
description: Declare Keiro DSL work queues, read-model-driven dispatch, read models, projection catalogs, and external reads.
docId: DOC-30
tags: [keiro, dsl, work-queues, read-models, reference]
generated:
  by: anthropic-claude-code/claude-opus-5
  at: 2026-09-28T00:00:00Z
---

# Keiro DSL Queues and Read Models

This page covers PGMQ work queues, read-model-driven dispatch, read models,
Language 5 projection catalogs, and external-read contracts. It is part of the [Keiro DSL Reference](keiro-dsl-reference.md), which
introduces the language, its versions, and source file structure.

## Work queues and dispatch

### Work queues

The grouped-head example below uses candidate Language 6 syntax.

```keiro
workqueue reservation_work {
  queue logical = "hospital_capacity.reservation_work"
  derive physical = "hospital_capacity_reservation_work"
         dlq = "hospital_capacity_reservation_work_dlq"
         table = "pgmq.q_hospital_capacity_reservation_work"

  ordering fifo-heads
  group key from reservationId via raw
  provision standard

  payload ReservationWorkItem {
    reservationId -> "reservation_id" text required
    hospitalId -> "hospital_id" text required
    attempts -> "attempts" int required
    urgent -> "urgent" bool required
  }

  retry maxRetries = 3 delay = 5s dlq = on

  disposition {
    storeFailure -> retry 5s
    commandRejected -> deadLetter
    decodeFailure -> deadLetter
    onCodecReject -> deadLetter
  }
}
```

The logical queue name is the durable source identity. The physical queue, DLQ,
and backing table are captured fixtures; `check` re-derives them and rejects
drift. Long or otherwise non-simple logical names may use a stable hashed
physical derivation; copy the values reported by the checker or a generated
starter rather than inventing them.

Payload rows are `field -> "wire_key" type [required]`. Language 4 closes the
type vocabulary to `text`, `int`, and `bool`, which lower to `Text`, `Int`, and
`Bool`; other words are rejected instead of silently becoming `Text`.
Every payload field is required: generated decoders read all of them with
`o .:`. The `required` marker is therefore accepted but selects nothing, and a
row written with it and a row written without it describe the same queue. For
the same reason, *adding* a payload row is a breaking change however it is
spelled — a job already queued under the old shape does not contain it. Queue
payload evolution is a persisted wire change and must go through `diff`.

Language 5 additionally reserves a colon form for a complete mapped
type expression:

```keiro
jobData -> "job_data" : List (Optional ArtifactInfo)
```

The colon is the language-5 feature boundary; languages 1 through 4 reject it
at that token and retain their released scalar interpretation. Language 5
scaffolding lowers the complete expression through the checked mapped graph,
imports the exact application-owned Haskell types, and emits structural field
codecs or opaque `ToJSON`/`FromJSON` boundaries. Required, optional, and
present-null behavior is explicit. The queue keeps its schema-version-1
`{v,t,data}` envelope; incompatible queued jobs still require a drain or a
declared transitional codec rather than an automatic upcaster.

Ordering is `unordered` (the default), `fifo-throughput`, `fifo-roundrobin`, or
`fifo-heads`. FIFO requires a group key; unordered queues reject one.
`fifo-heads` is the strict failure barrier and safely batches independent group
heads. It is Language 6 candidate syntax and is refused below Language 6 with
`LanguageFeatureRequiresVersion`; `unordered`, `fifo-throughput`, and
`fifo-roundrobin` remain available in every published language. The two legacy
FIFO fill modes require a runtime batch size of one.
`via raw` requires a `text` field. An opaque derivation uses:

```keiro
group key from reservationId via reservationGroup
  fixture "rsv_... => group-a"
```

The fixture captures the expected hand-owned derivation.

Provisioning is `standard` (the default), `unlogged`, or:

```keiro
provision partitioned(interval="daily", retention="7 days")
```

Unlogged queues are truncated after a PostgreSQL crash and produce a warning;
use them only for regenerable work. Partition interval and retention must be
non-empty and are create-time settings. Changing provisioning does not migrate
an existing queue.

`dlq=on` requires `maxRetries >= 1`. Language 4 rejects retry and queue-delay
durations whose unit-adjusted seconds do not fit in `Int`. The disposition
table contains all four named outcomes exactly once. `storeFailure` is
transient and retries; `decodeFailure` is poison and dead-letters. Generated
policy uses a closed queue-specific outcome type, so new rows and spelling
mistakes become compile errors in hand-owned handlers.

### Read-model-driven dispatch

```keiro
dispatch reservation_work_dispatch {
  source readModel = accepted_transfer_needs key = reservationId
  fanout body = resolveTransferCandidates
  dedup key = reservationId
        seenIn readModel = transfer_decisions field = reservation_id
        seenIn queue = reservation_work field = reservation_id
  enqueue to = reservation_work
}
```

The source and dedupe read models, dedupe column, dedupe queue, queue payload
field, and enqueue target must resolve. Under Language 4, the source key must
also name a generated logical selector for a column of the source read model
(`reservationId` resolves the SQL column `reservation_id`). `fanout body` names
a hand-owned effectful one-to-many function, not a column; it must be a
lowercase-initial identifier that could name a Haskell function. The top-level
`dedup key` obeys the same rule as the source key: it must name a generated
logical selector for a column of the source read model. The two `seenIn` fields
are the enforced dedupe boundaries. A dispatch is validated and diff-classified but produces no
generated module today. Keep the hand-owned queue-side SQL check consistent
with the declared wire key and read-model check.

## Read models

The first form below is the published Languages 1–4 compatibility grammar. It
keeps physical coordinates, delivery feed, and the historical consistency
vocabulary on the read model. Language 5 uses the catalog form later
in this section and does not accept those delivery/consistency fields.

```keiro
readmodel transfer_decisions {
  table = "transfer_decisions"
  schema = "hospital_capacity"
  columns {
    reservation_id text required
    hospital_id text required
    status text required
    decided_at timestamptz
  }
  version = 1
  shape = "fnv1a:3717f6d9e3c44bd6"
  consistency = Strong
  scope = category "reservation"
  feed = subscription
  subscription = "hospital-capacity-transfer-decisions-sub"
}
```

`schema`, `table`, and column names must be unquoted PostgreSQL identifiers:
`[a-z_][a-z0-9_]{0,62}`. Column names are unique. Supported SQL types are
`text`, `int`, `bigint`, `bool`, `timestamptz`, `jsonb`, and `numeric`.
`required` means non-null.

`version` starts at 1. `shape` is a captured FNV-1a-64 identity derived from
the table and ordered column surface. If it drifts, `check` prints the expected
value. Update the hash and bump `version` when the real table shape changes.

In Languages 1–4, consistency is `Strong` or `Eventual`. A strong model requires
`feed = subscription`; it cannot be inline-only because a strong read waits for
a subscription cursor. `scope` is legal only for a strong model and is either
`entire-log` or `category "name"`; omitted strong scope defaults to the entire
log. Feed is `inline` or `subscription`. An inline model must be referenced by
an aggregate projection of the same name. A `subscription` override beside
`feed = inline` is ignored and produces `RmInlineSubscriptionIgnored`. A
subscription name is optional for `feed = subscription`; the tool derives a
stable default when omitted. Under Language 4, explicit subscription and scope
category strings must satisfy the stable runtime-identity rules.

The SQL table remains application-migration-owned. The scaffold generates
schema-qualified table facts and create-once apply/query functions. Use the
generated table constant in SQL rather than depending on PostgreSQL
`search_path`.

Language 5 may declare the two type parameters of `ReadModel q r` as
one ordered pair after `columns`:

```keiro
query input = AccountLookup
query result = Optional AccountSummary
```

Both clauses are required together and resolve complete mapped type
expressions. Languages 1 through 4 reject the first `query` token; an omitted
second clause is a parse error rather than a partial semantic contract.

Scaffolding emits `Generated.<Context>.<ReadModel>.QueryContract`; its aliases use the exact
consumer domain types and deterministic imports. The generated `ReadModel` imports those aliases,
and a newly created hand-owned `ReadModelHoles` imports them for the application query signature.
No query JSON codec or SQL row conversion is generated. SQL columns, row codecs, DDL, migrations,
and query bodies remain application-owned.

If the output already contains a legacy create-once hole with local `QueryInput = ()` and
`QueryResult = ()` aliases, scaffolding preserves it and reports a migration obligation. Remove
those local aliases and import the generated pair; compilation stays red until that application
edit is complete. Query input/result changes are build-breaking API changes, but do not change the
read-model shape hash, catalog fingerprint, target reset policy, replay impact, or persisted
history. A legacy ledger without query-contract rows reports its baseline as unavailable rather
than guessing that the old API was `()`.

### Language 5 projection catalogs

Language 5 is the published stable authoring contract. It adds a closed
projection catalog without changing the meaning of any language-1–4 source. Do
not rewrite an existing language-4 workspace merely to follow the default; opt
in when the service is ready to declare the complete read-side inventory.

```keiro
language keiro-dsl 5
context catalog-demo

target order_summary {
  schema = "sales"
  table = "order_summary"
  reset = clear
}

target order_totals {
  schema = "sales"
  table = "order_totals"
  reset = clear
  depends-on = [ order_summary ]
}

rebuild-group reporting {
  targets = [ order_summary order_totals ]
  order = [ order_summary order_totals ]
}

projection-revision reporting_v2 {
  group = reporting
  target order_summary {
    schema-version = "v2"
    provisioner = "reporting-v2-order-summary"
    provisioner-version = 1
    expected-shape = "order-summary-v2"
    validator = "reporting-v2-order-summary-validator"
    validator-version = 1
    promotion index "order_summary_status_idx__v2" -> "order_summary_status_idx"
  }
  target order_totals {
    schema-version = "v2"
    provisioner = "reporting-v2-order-totals"
    provisioner-version = 1
    expected-shape = "order-totals-v2"
    validator = "reporting-v2-order-totals-validator"
    validator-version = 1
    promotion constraint "order_totals_pkey__v2" -> "order_totals_pkey"
  }
}

projection-owner order_summary_writer {
  source = aggregate Orders
  delivery = subscription
  group = reporting
  targets = [ order_summary order_totals ]
  order = 10
  subscription = "catalog-demo-orders"
  dedup = "catalog-demo-orders-v1"
  checkpoint-on-missing = from-beginning
  replay = explicit
}

readmodel orderSummary {
  columns {
    order_id text required
  }
  version = 1
  shape = "fnv1a:784e511a19f74c58"
  freshness = immediate
  group = reporting
  targets = [ order_summary ]
}
```

A `target` is the only physical schema/table authority. `reset = clear`
permits group preparation to truncate it; `preserve` leaves brownfield rows in
place for an explicit reconciliation adapter. `depends-on` names targets in
the same group and must be acyclic. A `rebuild-group` lists exactly its targets
and their deterministic preparation order.

A `projection-revision` is the executable and schema contract for every target in one
rebuild group. Its target set must equal the group's target set. Schema version,
provisioner, expected-shape, validator, and their positive versions are stable catalog
identity. Ordered `promotion index`, `promotion constraint`, and `promotion
owned-sequence` rows map generation-local object names to the canonical names that
application migrations address after promotion. The source contains no DDL. Generated
create-once holes receive `TargetProvisioningContext` for provision/validation and
`PhysicalTargets` for live, replay, and verification, so application SQL resolves the
serving or staging generation explicitly.

Each `projection-owner` selects exactly one typed source: `aggregate Name`,
`category "name"`, or `all`. Split independent sources into separate owners.
It owns at least one target in one group and has a globally unique numeric
handler order. Subscription delivery also requires `subscription` and `dedup`
identities and a query model that observes one of its targets. Inline delivery
must omit those identities. A subscription must also choose exactly one
`checkpoint-on-missing` policy: `from-beginning` replays retained history,
`from-current-head` starts with future events when no row exists, and `fail`
refuses startup until an operator provisions the checkpoint. Inline owners must
omit this policy because they have no durable checkpoint. A replayable owner of
a `reset = clear` target cannot choose `from-current-head`, because clearing the
target and skipping retained history cannot reconstruct it. `replay =
explicit` generates distinct live and replay apply holes. `replay = live-only
"reason"` generates no replay adapter
and is invalid for a clear target.

Target ownership is also query-supply authority. Every catalog-bound read model must
name a non-empty observed-target set whose members all belong to one projection owner
in the same rebuild group. Several read models may observe different subsets of one
owner's targets and resolve to that same owner. The owner handler is generated and
selected once per event source, independently of query count. Do not repeat the
relationship with an aggregate-local `projection <readmodel>` clause; Language 5
reports that as conflicting legacy ownership. A multi-target query's
`backing = <target>` still selects one physical SQL table and does not stand in for the
complete supplier check.

Projection delivery and query freshness are separate Language 5 axes:

```keiro
delivery = inline
delivery = subscription

freshness = immediate
freshness = wait-for-head entire-log
freshness = wait-for-head category "orders"
```

`immediate` performs no cursor wait and is valid for either owner delivery; an
immediate query supplied by a subscription owner may observe lag. `wait-for-head`
requires one compatible durable subscription cursor derived from the supplying
owner. Entire-log waits require an all-stream source. Category waits accept an
all-stream source or the same category. Inline/implicit owners, missing cursors,
several compatible cursors, or unreachable scopes fail checking as
`CatalogQueryWaitWithoutCompatibleCursor` or
`CatalogQueryWaitWithAmbiguousCursor`. A rebuild group mixing an all-stream owner
with category-scoped owners fails as `CatalogAmbiguousSourceOrdering`, matching
runtime catalog validation. Static Language 5 has no position-wait form; callers
use `runQueryWithFreshness (WaitForPosition options)` with a concrete append
position.

A catalog-bound `readmodel` is a typed query contract. It names its group and
observed targets, declares `freshness = immediate | wait-for-head ...`, and
deliberately omits `schema`, `table`, `feed`, `subscription`, `consistency`, and
`scope`. Physical coordinates belong to target declarations; delivery and cursor
identity derive from the resolved owner. The generated context-level
`Generated.<Context>.ProjectionCatalog` validates one runtime catalog, exports
typed owner/source inline views, `projectionCatalogQuerySupplies`,
registration/inventory functions, and group-scoped rebuild starters.
`<Context>.ProjectionCatalog.ProjectionCatalogHoles` is create-once
and owns live apply, replay apply, heterogeneous decoder, idempotency,
revision provision/validation, physical-target-parametric live/replay, and verification
bodies. Regeneration never overwrites reviewed hole code.

Language 5 also supports the bounded all-row external-read contract:

```keiro
external-read order_totals_reader {
  version = 1
  query = order_totals_lookup
  result-schema = "app_contract"
  result-type = "order_totals_row_v1"
  compatible-revisions = [ reporting_v1 reporting_v2 ]
  surface-generation = 1
}
```

The generated `Catalog.AllRowsExternalRead` obtains its result-shape hash from the
checked `readmodel`; the source cannot repeat or override it. The contract and SQL type
names must be lower-case PostgreSQL identifiers, the query must observe exactly one
target, and every compatible revision must belong to that query's group. Compatible
revision order is identity-neutral. Removing a contract, adding a version, changing its
compatibility set, and changing the query-derived result shape have distinct diff
findings.

All-row functions enforce the runtime's fixed 100-row boundary because caller predicates
cannot be pushed through their procedural wrapper; overflow raises `KR004` before any
partial result is returned. The create-once projection-catalog hole module also
scaffolds a `<contract>V<version>KeyedExternalRead` helper. Applications supply typed
SQL arguments and an application-owned private implementation function to that helper;
external roles still receive only the generated guarded wrapper. Language 5 does not
attempt arbitrary query-payload mapping. A future implementation of
[IR-25](../improvement-requests/make-derived-and-conditional-event-payload-mappings-declarative.md)
can generate the same runtime `KeyedExternalRead` declaration without changing its
contract.

A source of `aggregate Name` derives its mapped consumer dependencies from
that aggregate's private-event roots; inline aggregate projections use the
same event authority. Neither relation inherits command-only or register-only
mapped roots, nor queue/query roots declared elsewhere in the service. The
derived relation retains complete transitive paths such as
`Orders event OrderRecorded .payload : OrderPayload .reference : SharedReference`.
Scaffold output reports each typed inline/catalog consumer separately from its
operational group, targets, observing read models, replay policy, and source
fingerprint. Targets and query models are review/rebuild evidence, not a claim
that Keiro inferred SQL column dependencies.

A mapped private-event wire change updates the generated aggregate-source
fingerprint. The ordinary event compatibility finding remains authoritative for
stored payloads; projection findings additionally identify handlers that must
recompile and be reviewed. Replayable catalog owners invalidate their running
rebuild fingerprint and name their affected group. Inline and live-only owners
have build/review impact but no replay impact. Command-only, register-only, and
query-only mapped changes leave the aggregate-source fingerprint byte-stable.
`category` and `all` remain heterogeneous hand-decoded sources, so the checked
graph reports their unsupported typed boundary without inventing a mapped
consumer path.

Catalog declarations do not create tables, migrations, indexes, row codecs, or
SQL. They also cannot prove which tables an unrestricted Hasql transaction
writes. Keep application DDL and qualified SQL under the migration ownership
rules in [Migration Ownership](migration-ownership.md).
