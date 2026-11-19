---
type: Bug Report
title: An untraced timer reschedule clears the stored trace context
description: "scheduleTimerTx re-arms a scheduled timer with traceparent and tracestate set unconditionally from the new request, so a reschedule that carries no trace context overwrites the creation context with NULL and the eventual fire span is unlinked."
generated:
  by: process:claude-code
  at: "2026-11-19T02:28:18Z"
bugId: BUG-14
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-patterns
affects: mori://shinzui/keiro/packages/keiro
affectedVersion: "0.25.0.0"
environment: "Found by reading keiro master at 1ef8273f (0.26.0.0 sources) while reconciling mori://shinzui/keiro-runtime-patterns with the 0.26 cohort. The same statement ships in the keiro-0.25.0.0 and keiro-0.25.1.0 tags; it was introduced by 3bc78fab. The SQL behaviour was reproduced on PostgreSQL 17.11, aarch64-darwin, by running the statement text verbatim against a scratch table with the migration 0033 trace columns, not through the Haskell API."
observed: "After a timer is scheduled with a TimerRequest whose traceContext is Just, a second scheduleTimerTx for the same scheduled timerId with traceContext = Nothing leaves the row with traceparent and tracestate both NULL. The timer worker then opens `timer fire <manager>` with no creation link, exactly as for a legacy row."
expected: "docs/user/operations.md says timers persist creation context, that schedulers capture it only when their command tracer is configured, and that a supplied TimerRequest.traceContext wins. withTimerTraceContext documents that absence preserves the request without inspection. A reschedule that supplies no context should therefore keep the stored pair, and only a supplied context should replace it, while fire_at, payload and the other fields are re-armed as before."
reproduction:
  - Create a table shaped like keiro.keiro_timers after migration 0033, or apply the framework plan to a scratch database.
  - Prepare scheduleTimerStmt exactly as written in keiro/src/Keiro/Timer/Schema.hs (the INSERT … ON CONFLICT (timer_id) DO UPDATE … WHERE keiro_timers.status = 'scheduled').
  - Execute it for one timer_id with status 'scheduled' and a traceparent and tracestate, and select the row; both values are stored.
  - Execute it again for the same timer_id with a later fire_at and NULL traceparent and tracestate, as scheduleTimerTx does for a TimerRequest whose traceContext is Nothing.
  - Select the row; traceparent and tracestate are now NULL. The transcript and script are in evidence/BUG-14-untraced-reschedule-clears-trace-context.txt.
workaround: "Configure the same command tracer on every process manager and reaction that can re-arm a given timer, and call captureTimerTraceContext before any application-level scheduleTimer call, so every reschedule supplies a context. A reschedule made with a tracer but outside any span still writes NULL."
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-19T02:28:18Z"
    document_timestamp: "2026-11-19T02:28:18Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: "Reporter's evidence check: the statement text was read at keiro/src/Keiro/Timer/Schema.hs:689-718 and confirmed present in the keiro-0.25.0.0 and keiro-0.25.1.0 tags; the call sites were read in Keiro.Timer.captureTimerTraceContext, Keiro.ProcessManager and Keiro.Workflow.Sleep; the SQL was executed against a scratch table, not the full migration plan, and no keiro test was run. This is not independent owner confirmation."
---

# An untraced timer reschedule clears the stored trace context

This was found while reconciling the runtime-patterns catalog with Keiro 0.26.0.0.
Durable tracing (migration `0033`, commit `3bc78fab`) added nullable `traceparent`
and `tracestate` columns to `keiro.keiro_timers` and made the timer worker link
`timer fire <manager>` to the stored creation context.

## Observed behaviour

`scheduleTimerTx` upserts on `timer_id` and re-arms a row that is still `scheduled`:

```sql
ON CONFLICT (timer_id) DO UPDATE
  SET …
      traceparent = EXCLUDED.traceparent,
      tracestate = EXCLUDED.tracestate,
      …
  WHERE keiro_timers.status = 'scheduled'
```

Both trace columns are taken from the new request unconditionally. When the
rescheduling request has `traceContext = Nothing`, the stored context is replaced by
NULL:

```text
after traced schedule     | 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01 | vendor=a
after untraced reschedule | ∅                                                       | ∅
```

A request reaches the statement without context whenever its scheduler has no
tracer (`captureTimerTraceContext Nothing` returns the request unchanged), when a
tracer is configured but no span is current, and for application code that calls
`scheduleTimer` without capturing first. This happens, for example, during a
rolling deployment in which only some process-manager workers have a tracer. The
fire then looks like a legacy row: it runs normally, but its span has no creation link.

`scheduleTimerOnceTx` (workflow sleep) uses `DO NOTHING` and is not affected.

The severity is `degraded`, not `data-loss`. Domain state, `fire_at`, the payload
and firing are all correct. Only the advisory trace attribution is lost.

## Possible fix

Replace the two trace columns as a pair only when the request supplies a context:

```sql
traceparent = COALESCE(EXCLUDED.traceparent, keiro_timers.traceparent),
tracestate = CASE WHEN EXCLUDED.traceparent IS NULL
                  THEN keiro_timers.tracestate
                  ELSE EXCLUDED.tracestate END,
```

Keep `tracestate` tied to its `traceparent`, so that a supplied context with no
`tracestate` still clears the old one. Add a `DurableTracingSpec` case that
schedules a traced timer, re-arms it untraced, fires it, and expects the
`timer fire` span to carry the original creation link.

If replacing the context with NULL is intended, document it next to
`scheduleTimerTx` and in the operations guide's timer tracing paragraph.
