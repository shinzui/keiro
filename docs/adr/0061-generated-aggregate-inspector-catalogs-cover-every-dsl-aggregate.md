---
type: Architecture Decision Record
title: Generated aggregate inspector catalogs cover every DSL aggregate
description: keiro-dsl emits one context-level Inspection module whose inspector catalog is complete by construction, displays state through the aggregate's own codec or its vertex, and uses empty values instead of Maybe.
timestamp: 2026-11-16T18:40:00Z
docId: ADR-61
status: Accepted
date: 2026-11-16
originatingPlan: docs/plans/336-generate-an-aggregate-inspector-catalog-for-every-keiro-dsl-aggregate.md
---

# Generated aggregate inspector catalogs cover every DSL aggregate

## Context

The keiro-ui inspection surface lists aggregate types and shows folded state through
`Keiro.Ops.AppHooks`. Its `aggregates` hook takes application-supplied
`AggregateInspector` descriptors.
[ADR-54](0054-aggregate-inspection-reuses-hydration-without-diagnostics-on-the-command-path.md)
requires those descriptors and their display encoders to be explicit, because a snapshot
encoding is not implicitly a display contract. keiro-dsl already generated the other two
read-only inputs, the replay-audit targets and the projection catalog. DSL services
therefore wrote inspectors by hand. Nothing stopped a newly declared aggregate from being
left out of the console, so services added guard tests whose only job was to catch that
omission.

## Decision

keiro-dsl emits `<contextGeneratedPrefix>.Inspection` for every service context that emits a
ReplayAudit module (at least one aggregate) or a ProjectionCatalog module (at least one
projection-catalog declaration). It sits beside those modules because catalogs and workspaces
are one per context
([ADR-26](0026-projection-catalogs-separate-query-target-group-and-handler-identities.md),
[ADR-14](0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)).
A context with neither emits nothing, so contract-only fragments gain no `keiro` or `aeson`
dependency. The module exports `aggregateInspectorCatalog`, the validated
`aggregateInspectors` map, `inspectionAuditTargets`, and `inspectionProjectionCatalog`.

The catalog is complete by construction. It is regenerated from the same checked
specification and the same aggregate node list as ReplayAudit, including process saga
aggregates. Each inspector is named by the aggregate's category text, so its name equals the
matching replay-audit category. Aggregate names are unique and the category derivation is
injective, so validation cannot fail; a violation fails loudly on evaluation.

The display rule is the generated, explicit choice ADR-54 asks for, limited to DSL aggregates.
The generated helper reads the definition's own `stateCodec` field and never re-derives the
snapshot predicate, so it cannot drift from the codec the event stream uses. A snapshot
aggregate displays through its `defaultStateCodec` as `{"state": …, "registers": {…}}`. That
shows every register without redaction, and before a register is first written it shows the
generated placeholder initial value. Any other aggregate displays only `{"state": "<vertex>"}`,
even when it has registers. A service that needs redaction or another shape writes its own
inspector and does not mount the generated catalog.

Absent sections are empty values, never `Maybe`. A context without a projection catalog gets
the validated `emptyProjectionCatalog`. A projections-only context gets empty inspector and
audit-target lists. Every host therefore mounts the read-only surface with the same three
`emptyAppHooks` fields.

The generated module depends only on `keiro`, `keiki`, `aeson`, and `text`, never on
`keiro-ops`, which brings migrations and PGMQ. keiro-ops gains no helper because a record
update of `emptyAppHooks` already expresses the mount.

## Consequences

- Hosts mount aggregate, replay-audit, and projection inspection from three generated values.
  Hand-written completeness guards become unnecessary.
- The module is inert data until a host imports it, which preserves the bounded inspection
  exception of
  [ADR-40](0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md). Command
  paths gain nothing.
- Adding the module is additive. DSL source, checking, language versions, and existing
  generated modules are unchanged, so old generated output compiles against the new runtime
  and needs no upgrade edge. Regenerating adds one module that the consuming Cabal stanza must
  list.
- Generated library imports are unqualified with explicit lists. The library
  `aggregateInspectors` is reached only through its full module name. A single-segment
  aggregate alias such as `Stream` or `Text` therefore cannot collide with a library alias.
- A corpus suite that leaves its ReplayAudit, an aggregate EventStream, or its
  ProjectionCatalog uncompiled must also exempt its Inspection module, which imports them.
