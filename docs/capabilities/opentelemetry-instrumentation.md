---
title: "OpenTelemetry instrumentation"
type: Capability
description: "Emit bounded OpenTelemetry spans and metrics across commands, projections/rebuilds, dispatch, messaging, timers, workflows, and PGMQ jobs, with W3C propagation across durable boundaries."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
capabilityId: CAP-15
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro
  - keiro-pgmq
interface:
  - Keiro.Telemetry
  - Keiro.PGMQ.Metrics
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'Keiro.Telemetry metrics', 'Keiro.Telemetry', 'Kiroku retry exhaustion observability', and 'Keiro.Workflow observability' describe blocks assert that spans and metrics carry the expected common surface across deliveries and handlers."
  - kind: guide
    resource: docs/user/operations.md
    proves: "How to wire an OTel exporter and what telemetry keiro emits for operating a deployment."
  - kind: test
    resource: keiro-pgmq/test/Main.hs
    proves: "PGMQ jobs propagate W3C trace context across enqueue/settlement and record bounded queue, attempt, retry, completion, and dead-letter metrics."
  - kind: module
    resource: keiro/src/Keiro/Telemetry.hs
    proves: "The telemetry surface: span kinds and the common attribute set applied across delivery and handler paths."
---

# OpenTelemetry instrumentation

keiro emits OpenTelemetry spans and metrics across its delivery and handler paths
— the command cycle, projections, process-manager and router dispatch, timers,
catalog rebuilds, durable workflows, and PGMQ jobs — with a common bounded
attribute surface and W3C trace context propagated through durable messaging
boundaries. A consumer wires its own
OTel exporter and gets end-to-end traces and operational metrics without having
to instrument the framework internals.

Outcome-aware commands emit only `accepted`, `rejected`, or `no_op`; typed
application reasons are deliberately excluded from attributes and metric
dimensions. Read-model distance is measured in global-position units from the
newest visible head, and versioned rebuild metrics distinguish starts, resumptions,
pages/events, failures, promotions, and duration without inventing an event-count
lag.

This is recorded as a capability because configuring telemetry is a real,
separate adoption decision with its own module and its own evidence, even though
the spans it produces span the other capabilities.

## Shape

```haskell
import Keiro.Telemetry
-- run under an effectful OpenTelemetry tracer/exporter of your choice;
-- keiro's runners open the spans and record the metrics.
```

## Limits

- keiro produces telemetry but does not ship an exporter or a collector; the
  consumer supplies and operates the OTel backend. What is guaranteed is the
  span/metric surface, not delivery to any particular observability system.
- Coverage is the delivery and handler paths the runtime controls. Work a
  consumer does inside a filled handler is only traced if the consumer opens its
  own child spans.
