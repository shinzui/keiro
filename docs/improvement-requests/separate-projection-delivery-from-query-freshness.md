---
type: Improvement Request
title: Separate projection delivery from query freshness
description: >-
  Stop using read-model feed and Strong/Eventual consistency names for two independent concerns;
  let projection owners declare event-delivery mode and let query models declare an honestly named
  immediate, head-wait, or position-wait freshness policy.
timestamp: 2026-08-12T02:19:21Z
requestId: IR-24
status: completed
plan: docs/masterplans/38-finalize-projection-ownership-and-query-freshness-before-stable-language-5.md
origin: mori://tan/notification-render-service
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-08-12T02:19:21Z
    document_timestamp: 2026-08-12T02:19:21Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against Keiro.ReadModel ConsistencyMode, runQuery/runQueryWith, StrongScope and
      subscription cursor behavior; Language 5 read-model and projection-owner grammar; and the
      typed projection catalog. The request separates writer delivery from query waiting, keeps
      released Languages 1–4 unchanged, and requires a compatibility path for the released runtime
      API rather than treating a keyword rename as the whole fix.
---

# Improvement Request: Separate Projection Delivery from Query Freshness

## Status

**Implemented.** [MasterPlan 38](../masterplans/38-finalize-projection-ownership-and-query-freshness-before-stable-language-5.md)
delivered owner-only Language 5 `delivery`, query-only `freshness`, truthful
runtime builders and wait policies, deterministic cursor-capability validation,
separate evolution/conformance facts, and the 0.12-to-0.13 compatibility path.
Plans [244](../plans/244-introduce-truthful-query-freshness-runtime-apis-with-compatibility.md)
and [245](../plans/245-separate-language-5-projection-delivery-from-query-freshness.md)
record the runtime and candidate-language evidence.

The request-time examples and analysis below preserve the misleading candidate
surface that motivated the change. They are historical evidence, not current
Language 5 authoring syntax. The request was raised by
`mori://tan/notification-render-service` while reviewing the imminent Keiro
0.12 runtime and stable DSL Language 5. The review exposed this then-valid
declaration:

```keiro
readmodel catalog_query {
  consistency = Eventual
  feed = inline
  # ...
}
```

The catalog projection is applied in the same transaction as the event append, so the resulting
target is not eventually updated. `Eventual` means only that `runQuery` executes immediately
without waiting on a subscription cursor. Meanwhile `feed = inline` describes how events reach
the writer, not how the query reads. Putting both properties on the read model makes independent
concepts look contradictory.

This request depends conceptually on
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-23`, which makes the Language 5 catalog
projection owner authoritative for supplying read models. IR-23 is the small release-blocking
ownership repair. This request completes the language model and terminology without enlarging
IR-23 into a runtime/API migration.


## Context

Keiro currently has two independent axes.

**Projection delivery/application.** A projection handler is either:

- inline, where command append and target writes share one database transaction; or
- subscription-driven, where a worker consumes events later and advances a durable cursor.

Language 5 already places this behavior on `projection-owner` as `feed = inline | subscription`.
The read model repeats a `feed` field even though a query model does not consume events itself; its
targets' projection owner does.

**Query freshness/waiting.** `Keiro.ReadModel.ConsistencyMode` controls what `runQuery` does before
executing SQL:

- `Eventual` runs immediately after schema and liveness checks;
- `Strong` captures the configured entire-log or category head at query start and waits until one
  subscription cursor reaches that position; and
- `PositionWait options` waits for a caller-supplied global position when present.

Those are query waiting policies, not projection delivery modes. Their current names overstate or
misstate the guarantee:

- `Eventual` does not make an inline target eventual; it means **do not wait**.
- `Strong` is not general strong consistency or linearizability. It is a bounded wait for a
  particular subscription to reach a head captured at query start. Events committed after the
  capture are outside that wait.
- `PositionWait` is already close to its real meaning but is usually a per-call override rather
  than a static property of how the target is maintained.

The current validator exposes the conceptual leak. It rejects `Strong` on an inline read model
because no subscription cursor exists to advance, then instructs the author to use `Eventual`.
That validation prevents a timeout, but the resulting source reads as “inline yet eventual.”

Earlier Keiro research used `Strong` and `Eventual` to name projection lifecycles. The runtime later
gave `Strong` the concrete subscription-head wait behavior. The implementation is internally
coherent; the vocabulary is what failed to evolve with it.


## Requested Change

Represent writer delivery and query freshness as distinct, single-owner concepts in stable
Language 5 and expose equally honest runtime terminology.

1. Make the catalog `projection-owner` the only Language 5 declaration of event-delivery mode.
   A read model declares the targets it queries and derives their supplying owner/delivery through
   the validated catalog. Do not require or permit a redundant read-model `feed` when the model is
   catalog-managed.
2. Rename the Language 5 projection-owner property from `feed` to an unambiguous term such as
   `delivery`, with values `inline` and `subscription`. The final spelling must describe handler
   scheduling/application rather than query consistency. Because Language 5 is not yet stable,
   choose and freeze the clear spelling before release.
3. Replace Language 5 read-model `consistency = Strong | Eventual` with a query-focused property
   such as `freshness = immediate | wait-for-head`. Preserve the head scope as part of the
   wait-for-head policy rather than as a meaningful field on an immediate query.
4. Use runtime names that state the operation performed. A suitable semantic vocabulary is
   `Immediate`, `WaitForHead scope/options`, and `WaitForPosition options`; exact Haskell layout may
   differ, but public Haddocks and generated code must not call an immediate inline read
   “eventual” or a captured-head cursor wait generically “strong.”
5. Keep caller-targeted position waiting available through `runQueryWith`. Do not force a dynamic
   global position into static DSL source. If a default position-wait mode with no target is
   retained, document that it is operationally identical to immediate execution and justify why
   that state is useful.
6. Validate capability rather than memorized keyword pairs. `wait-for-head` requires an
   unambiguous durable subscription cursor capable of reaching the declared scope. Immediate reads
   require no cursor and are valid for both inline and subscription-maintained targets. A query
   spanning targets with incompatible or multiple cursor authorities must choose an explicitly
   supported multi-cursor policy or fail validation.
7. Derive generated `ReadModel` freshness configuration and any cursor identity from the validated
   owner/query relation. Do not select the first matching owner or read model by list order.
8. Preserve Languages 1–4 byte-for-byte. They may continue to parse and scaffold `feed` plus
   `consistency = Strong | Eventual` under their frozen language contracts.
9. Provide a source-compatible runtime adoption path for applications compiled against
   `ConsistencyMode`, `Strong`, `Eventual`, `PositionWait`, `StrongScope`, and
   `defaultStrongWaitOptions`. Deprecated pattern synonyms, conversion functions, or a staged
   major-version removal are acceptable; silently changing existing constructor semantics is not.
10. Update generated harness facts, diff/evolution classification, CLI explanations, authoring
    guides, API reference, research-history annotations, examples, and changelog. Documentation
    must consistently distinguish **when projection writes happen** from **whether a query waits**.


## Illustrative Language 5 Shape

The exact keywords remain an implementation design choice, but the resulting source should read
like this:

```keiro
readmodel validate_layout {
  columns {}
  query input = LayoutValidationInput
  query result = Optional LayoutContract
  version = 1
  shape = "fnv1a:3c07a19c552c3547"
  freshness = immediate
  group = catalog_views
  targets = [ catalog_layouts ]
}

projection-owner catalog_writer {
  source = aggregate Catalog
  delivery = inline
  group = catalog_views
  targets = [ catalog_state catalog_layouts catalog_keys ]
  order = 10
  replay = explicit
}
```

For an asynchronous query that should wait for its category projection to catch up to the head:

```keiro
readmodel list_templates {
  # typed query and shape declarations omitted
  freshness = wait-for-head category "notificationType"
  group = notification_views
  targets = [ template_state ]
}

projection-owner notification_views_writer {
  source = aggregate NotificationType
  delivery = subscription
  subscription = "notification-renderer-domain-notification-views"
  dedup = "notification-renderer-domain-notification-views-v1"
  checkpoint-on-missing = from-beginning
  # group, targets, order, and replay omitted
}
```

The first query runs immediately against a target maintained transactionally. The second waits for
one declared subscription to reach the relevant captured category head. Neither source asks the
reader to infer those meanings from `Eventual`, `Strong`, or a duplicated `feed` field.


## Acceptance

1. A Language 5 inline catalog projection owner and an immediate read model check and scaffold
   without any read-model delivery/feed declaration. Generated `runQuery` performs no cursor wait,
   and docs describe the target as transactionally maintained rather than eventually consistent.
2. A subscription owner plus a `wait-for-head` read model resolves exactly one compatible cursor
   and scope, waits for the captured head, and times out with the existing typed error behavior.
3. A subscription-maintained read model with `immediate` freshness is accepted and may return stale
   data by explicit author choice. The docs state that trade-off directly.
4. A `wait-for-head` read model supplied only by an inline owner is rejected because no cursor can
   satisfy the wait. The diagnostic names the query model, owner, delivery mode, and missing cursor
   capability without recommending an “Eventual” consistency label.
5. Per-call `WaitForPosition` returns read-your-write behavior for an asynchronous projection using
   the append position supplied by the caller. It remains independent of the model's default
   immediate/head-wait policy.
6. Reordering owners, query models, or observed targets cannot change the cursor or freshness
   configuration selected by generated code.
7. Languages 1–4 parse, validate, scaffold, diff, and round-trip existing `feed` and
   `Strong`/`Eventual` sources byte-identically.
8. Existing Haskell applications have a documented compatibility path and tests prove old names
   retain old semantics throughout the deprecation window.
9. Generated conformance and diff output identify delivery changes separately from query-freshness
   changes. Moving an owner from inline to subscription remains a projection lifecycle change;
   moving a query from immediate to head-wait remains a query policy change.
10. The API reference, typed-spec guide, read-model guide, at least one compiled catalog fixture,
    and release notes use the new terminology consistently and contain no example described as
    “inline with eventual consistency.”


## Compatibility and Scope

This request changes candidate Language 5 source and public terminology. It does not change the
underlying transactional guarantee of inline projection application, Kiroku subscription
checkpoint semantics, read-model table schema, event wire formats, projection fencing, or
application migration ownership.

It does not request zero-lag asynchronous delivery or make an immediate async query fresh. It
makes that trade-off explicit. It also does not solve out-of-process rebuild fencing, which remains
owned by `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-22`.

IR-23 should land first or in the same pre-release initiative because deriving delivery requires
the catalog owner/read-model relationship it establishes. The explicit multi-target `backing`
work in `mori://shinzui/keiro/plans/234-bind-catalog-read-models-to-one-explicit-physical-target`
remains orthogonal: backing selects the generated physical table identity, while this request
selects event delivery and query waiting policies.


## Requested Deliverables

- A Language 5 grammar and semantic model with owner-only delivery and query-only freshness.
- Capability-based owner/cursor resolution with deterministic diagnostics and no positional
  selection.
- Truthfully named runtime freshness API plus a tested compatibility/deprecation layer.
- Separate diff, scaffold-ledger, and generated-conformance facts for delivery and freshness.
- Positive and negative single-file/workspace fixtures covering inline/immediate,
  subscription/immediate, subscription/head-wait, and per-call position wait.
- Updated ADR terminology, authoring/API guides, examples, research annotations, corpus index, and
  changelog before Language 5 is declared stable.


## References

- Originating consumer: `mori://tan/notification-render-service`.
- Affected runtime package: `mori://shinzui/keiro/packages/keiro`.
- Affected toolchain package: `mori://shinzui/keiro/packages/keiro-dsl`.
- Inline ownership prerequisite:
  `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-23`.
- Typed catalog foundation: `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-20`.
- External-reader fence: `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-22`.
- Projection identity ADR: `mori://shinzui/keiro/okf/adrs/concepts/ADR-26`.
