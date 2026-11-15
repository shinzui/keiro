---
title: "OpenTelemetry instrumentation"
type: Capability
description: "Emit bounded OpenTelemetry spans and metrics across commands, projections/rebuilds, dispatch, messaging, timers, workflows, and PGMQ jobs, with W3C propagation across durable boundaries."
generated:
  by: openai/codex
  at: "2026-11-15T01:15:00Z"
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
    resource: keiro/test/DurableTracingSpec.hs
    proves: "A real command/subscription reaction/timer/workflow chain links exact wake and origin beyond snapshots; traced signals and child completions preserve replay and idempotent metadata."
  - kind: test
    resource: keiro/test/Main.hs
    proves: "All six subscription workers correlate processing spans using adapter policy; the actual Kiroku command/event/manager/command/event chain preserves creation context and child parenting."
  - kind: test
    resource: keiro/retention/Retention/SpanOwnership.hs
    proves: "Actual subscription helpers release envelopes and lazy attribute projections while exported spans remain alive under both correlation policies."
  - kind: test
    resource: keiro/test/Main.hs
    proves: "Producer cutoff survives restart, rollback and successful-row GC; batch send spans are roots with bounded per-message links and restore ambient context."
  - kind: test
    resource: keiro/test/Main.hs
    proves: "All four command entry points stamp one creation context across a multi-event batch; retries preserve it, explicit caller context wins, and no configured tracer leaves metadata unchanged inside an ambient span."
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'Keiro.Telemetry metrics', 'Keiro.Telemetry', 'Kiroku retry exhaustion observability', and 'Keiro.Workflow observability' describe blocks assert that spans and metrics carry the expected common surface across deliveries and handlers."
  - kind: guide
    resource: docs/user/operations.md
    proves: "How to wire an OTel exporter and what telemetry keiro emits for operating a deployment."
  - kind: test
    resource: keiro-pgmq/test/Main.hs
    proves: "PGMQ worker and bounded-drain paths share process naming, creation links and ParentAndLink/LinkOnly policy; actual decoded payloads collect while exported spans remain alive. Delayed/retried LinkOnly deliveries use independent roots."
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

Traced commands record W3C creation context in event metadata once per run, before retries.
Caller-supplied `traceparent` is preserved. Command span names are category-based (`command order`)
with the full stream name retained as an attribute. Untraced commands do not read ambient context.

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

Timers store creation context in nullable columns; firing opens a root with a creation link.
Workflow resumes use an advisory suspension hint and bounded event reads to recover exact
wake and journal-origin links independently of snapshot hydration. Existing untraced APIs
remain available; enable wake-source tracing explicitly. Retained-span probes exercise
actual fetched timer/journal rows, and separate timer/workflow legs enforce bounded live heap.

## Limits

- keiro produces telemetry but does not ship an exporter or a collector; the
  consumer supplies and operates the OTel backend. What is guaranteed is the
  span/metric surface, not delivery to any particular observability system.
- Coverage is the delivery and handler paths the runtime controls. Work a
  consumer does inside a filled handler is only traced if the consumer opens its
  own child spans.

Workflow origin/wake links are added after span creation; head samplers cannot inspect them.
