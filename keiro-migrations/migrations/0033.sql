-- persist timer creation context and workflow trace await hints
ALTER TABLE keiro.keiro_timers
  ADD COLUMN traceparent text,
  ADD COLUMN tracestate text;

-- Advisory attribution only: this hint never controls readiness or replay.
ALTER TABLE keiro.keiro_workflows
  ADD COLUMN trace_awaited_step text;
