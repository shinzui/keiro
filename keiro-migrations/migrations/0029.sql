-- Bound schema-versioned promotion attempts and stage async redelivery evidence.

ALTER TABLE keiro.keiro_projection_rebuild_runs
  ADD COLUMN promotion_dedup_limit BIGINT,
  ADD COLUMN dedup_provisional_head BIGINT,
  ADD COLUMN promotion_prepared_at TIMESTAMPTZ;

UPDATE keiro.keiro_projection_rebuild_runs
SET promotion_dedup_limit = 1000000
WHERE rebuild_mode = 'versioned';

ALTER TABLE keiro.keiro_projection_rebuild_runs
  DROP CONSTRAINT keiro_projection_rebuild_runs_mode_chk,
  ADD CONSTRAINT keiro_projection_rebuild_runs_mode_chk
    CHECK (
      (
        rebuild_mode = 'offline'
        AND candidate_revision_id IS NULL
        AND cutover_threshold IS NULL
        AND cutover_lock_timeout_ms IS NULL
        AND promotion_dedup_limit IS NULL
        AND dedup_provisional_head IS NULL
        AND promotion_prepared_at IS NULL
        AND history_retention_lease_id IS NULL
        AND history_retention_lease_owner IS NULL
        AND history_retention_protected_through IS NULL
        AND history_retention_expires_at IS NULL
        AND history_retention_renewed_at IS NULL
        AND history_retention_released_at IS NULL
      )
      OR (
        rebuild_mode = 'versioned'
        AND candidate_revision_id IS NOT NULL
        AND cutover_threshold IS NOT NULL
        AND cutover_threshold >= 0
        AND cutover_lock_timeout_ms IS NOT NULL
        AND cutover_lock_timeout_ms > 0
        AND promotion_dedup_limit IS NOT NULL
        AND promotion_dedup_limit > 0
        AND (dedup_provisional_head IS NULL OR dedup_provisional_head >= 0)
        AND history_retention_lease_id IS NOT NULL
        AND history_retention_lease_owner IS NOT NULL
        AND length(history_retention_lease_owner) > 0
        AND history_retention_protected_through IS NOT NULL
        AND history_retention_protected_through >= 0
        AND history_retention_expires_at IS NOT NULL
        AND history_retention_renewed_at IS NOT NULL
      )
    );

CREATE TABLE keiro.keiro_projection_rebuild_dedup_stage (
  run_id TEXT NOT NULL
    REFERENCES keiro.keiro_projection_rebuild_runs (run_id) ON DELETE CASCADE,
  subscription_name TEXT NOT NULL,
  projection_name TEXT NOT NULL,
  event_id UUID NOT NULL,
  global_position BIGINT NOT NULL,
  PRIMARY KEY (run_id, projection_name, event_id),
  CONSTRAINT keiro_projection_rebuild_dedup_stage_names_chk
    CHECK (length(subscription_name) > 0 AND length(projection_name) > 0),
  CONSTRAINT keiro_projection_rebuild_dedup_stage_position_chk
    CHECK (global_position > 0)
);

CREATE INDEX keiro_projection_rebuild_dedup_stage_run_position_idx
  ON keiro.keiro_projection_rebuild_dedup_stage
    (run_id, subscription_name, global_position);

-- Each helper catches only lock/deadline failures. That keeps the transaction
-- usable long enough for Keiro to return a typed retryable lifecycle outcome;
-- every other SQL error remains an ordinary database failure.
CREATE FUNCTION keiro.keiro_try_projection_cutover_fence_v1(
  requested_run_id TEXT,
  requested_contract TEXT,
  attempt_deadline TIMESTAMPTZ
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  remaining_ms BIGINT;
  fenced BOOLEAN;
BEGIN
  remaining_ms := ceil(extract(epoch FROM (attempt_deadline - clock_timestamp())) * 1000);
  IF remaining_ms <= 0 THEN
    RETURN 'deadline-exceeded';
  END IF;
  PERFORM set_config('lock_timeout', remaining_ms::text || 'ms', true);
  PERFORM set_config('statement_timeout', remaining_ms::text || 'ms', true);
  BEGIN
    UPDATE keiro.keiro_projection_rebuild_groups AS groups
    SET status = 'cutover-versioned', writes_allowed = FALSE, updated_at = now()
    FROM keiro.keiro_projection_rebuild_runs AS runs
    WHERE runs.run_id = requested_run_id
      AND runs.contract_fingerprint = requested_contract
      AND runs.status = 'running'
      AND groups.group_id = runs.group_id
      AND groups.status = 'rebuilding-versioned'
      AND groups.active_run_id = runs.run_id
      AND NOT EXISTS (
        SELECT 1 FROM keiro.keiro_projection_rebuild_sources AS sources
        WHERE sources.run_id = runs.run_id
          AND sources.exhausted_through IS DISTINCT FROM sources.target_position
      )
    RETURNING TRUE INTO fenced;
  EXCEPTION
    WHEN lock_not_available OR query_canceled THEN
      RETURN 'deadline-exceeded';
  END;
  IF coalesce(fenced, FALSE) THEN
    RETURN 'fenced';
  END IF;
  RETURN 'not-ready';
END;
$$;

CREATE FUNCTION keiro.keiro_try_projection_promotion_lock_v1(
  requested_run_id TEXT,
  requested_contract TEXT,
  attempt_deadline TIMESTAMPTZ
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  remaining_ms BIGINT;
  locked_run_id TEXT;
BEGIN
  remaining_ms := ceil(extract(epoch FROM (attempt_deadline - clock_timestamp())) * 1000);
  IF remaining_ms <= 0 THEN
    RETURN 'deadline-exceeded';
  END IF;
  PERFORM set_config('lock_timeout', remaining_ms::text || 'ms', true);
  PERFORM set_config('statement_timeout', remaining_ms::text || 'ms', true);
  BEGIN
    SELECT runs.run_id INTO locked_run_id
    FROM keiro.keiro_projection_rebuild_runs AS runs
    JOIN keiro.keiro_projection_rebuild_groups AS groups
      ON groups.group_id = runs.group_id
    WHERE runs.run_id = requested_run_id
      AND runs.contract_fingerprint = requested_contract
      AND runs.status = 'cutover'
      AND runs.promotion_prepared_at IS NOT NULL
      AND groups.status = 'cutover-versioned'
      AND groups.active_run_id = runs.run_id
      AND NOT EXISTS (
        SELECT 1 FROM keiro.keiro_projection_rebuild_sources AS sources
        WHERE sources.run_id = runs.run_id
          AND sources.exhausted_through IS DISTINCT FROM sources.target_position
      )
    FOR UPDATE OF runs, groups;
  EXCEPTION
    WHEN lock_not_available OR query_canceled THEN
      RETURN 'deadline-exceeded';
  END;
  IF locked_run_id IS NOT NULL THEN
    RETURN 'locked';
  END IF;
  RETURN 'not-ready';
END;
$$;

CREATE FUNCTION keiro.keiro_try_projection_relation_locks_v1(
  relation_oids BIGINT[],
  attempt_deadline TIMESTAMPTZ
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  remaining_ms BIGINT;
  relation_list TEXT;
  resolved_count BIGINT;
BEGIN
  remaining_ms := ceil(extract(epoch FROM (attempt_deadline - clock_timestamp())) * 1000);
  IF remaining_ms <= 0 THEN
    RETURN FALSE;
  END IF;

  SELECT
    string_agg(format('%I.%I', namespaces.nspname, relations.relname), ', ' ORDER BY requested.ordinality),
    count(*)
  INTO relation_list, resolved_count
  FROM unnest(relation_oids) WITH ORDINALITY AS requested(relation_oid, ordinality)
  JOIN pg_class AS relations ON relations.oid = requested.relation_oid
  JOIN pg_namespace AS namespaces ON namespaces.oid = relations.relnamespace;

  IF resolved_count IS DISTINCT FROM cardinality(relation_oids) OR relation_list IS NULL THEN
    RAISE EXCEPTION 'one or more promotion relations no longer exist';
  END IF;

  -- Object resolution is part of the attempt. Recompute immediately before the
  -- cumulative lock so time already spent under the group lock is not restored.
  remaining_ms := ceil(extract(epoch FROM (attempt_deadline - clock_timestamp())) * 1000);
  IF remaining_ms <= 0 THEN
    RETURN FALSE;
  END IF;
  PERFORM set_config('lock_timeout', remaining_ms::text || 'ms', true);
  PERFORM set_config('statement_timeout', remaining_ms::text || 'ms', true);
  BEGIN
    EXECUTE 'LOCK TABLE ' || relation_list || ' IN ACCESS EXCLUSIVE MODE';
  EXCEPTION
    WHEN lock_not_available OR query_canceled THEN
      RETURN FALSE;
  END;
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION keiro.keiro_try_projection_cutover_fence_v1(TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION keiro.keiro_try_projection_promotion_lock_v1(TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION keiro.keiro_try_projection_relation_locks_v1(BIGINT[], TIMESTAMPTZ) FROM PUBLIC;
