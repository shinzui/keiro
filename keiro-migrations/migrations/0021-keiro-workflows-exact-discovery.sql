-- Exact discovery: the resume worker now returns a workflow only when its
-- instance row says it has progress to make — status 'running', or status
-- 'suspended' with a due wake_after hint. The status-only active index cannot
-- serve the second arm, so replace it with one that also carries wake_after.
-- The index predicate is unchanged, so the swap is transparent to every other
-- reader of the active set.
DROP INDEX IF EXISTS keiro.keiro_workflows_active_idx;
CREATE INDEX IF NOT EXISTS keiro_workflows_active_idx
  ON keiro.keiro_workflows (status, wake_after)
  WHERE status IN ('running', 'suspended');

-- Legacy suspensions predate exact discovery: before this change a 'suspended'
-- row was re-examined on every pass, so a workflow could be parked on a promise
-- that was already cancelled, or on a wake whose row-lifecycle transition was
-- never reflected in the instance row, and nothing would ever flip it again.
-- Return every suspended instance to the runnable pool once. The next pass
-- re-examines each and re-suspends it through the new suspend/wake arbitration,
-- which is what makes the row's status trustworthy from then on. The cost is one
-- extra replay per legacy suspended instance, once.
UPDATE keiro.keiro_workflows SET status = 'running', updated_at = now()
WHERE status = 'suspended';
