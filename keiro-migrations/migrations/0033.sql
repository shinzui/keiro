-- restore lock and statement timeouts after guarded cutover attempts
--
-- 0029 applied the cutover budget with set_config(..., true), which is
-- transaction-local rather than statement-local, and never restored it. The
-- budget therefore stayed in force for the remainder of the promotion
-- transaction. Everything after the guarded statement -- generation identity
-- verification, the promotion object map check, the table renames, the
-- promotion metadata writes, and external read reconciliation -- ran under a
-- statement_timeout sized for acquiring a lock, not for doing that work.
--
-- A promotion that successfully acquired its ACCESS EXCLUSIVE locks could then
-- be cancelled partway through with an unhandled 57014, after the locks were
-- taken, surfacing as an opaque UnexpectedServerError rather than the
-- documented VersionedCutoverDeadlineExceeded. The larger the promotion, the
-- likelier it was, because the remaining budget shrinks as the attempt
-- proceeds while the work after the lock does not.
--
-- Each function now captures the prior settings, applies the budget across its
-- guarded statement only, and restores them on both the success and the
-- timeout path. The guarded statement keeps exactly the bounds it had, so
-- lock-acquisition behaviour and every returned verdict are unchanged.

CREATE OR REPLACE FUNCTION keiro.keiro_try_projection_cutover_fence_v1(
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
  prior_lock_timeout TEXT;
  prior_statement_timeout TEXT;
BEGIN
  remaining_ms := ceil(extract(epoch FROM (attempt_deadline - clock_timestamp())) * 1000);
  IF remaining_ms <= 0 THEN
    RETURN 'deadline-exceeded';
  END IF;
  prior_lock_timeout := current_setting('lock_timeout');
  prior_statement_timeout := current_setting('statement_timeout');
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
      PERFORM set_config('lock_timeout', prior_lock_timeout, true);
      PERFORM set_config('statement_timeout', prior_statement_timeout, true);
      RETURN 'deadline-exceeded';
  END;
  PERFORM set_config('lock_timeout', prior_lock_timeout, true);
  PERFORM set_config('statement_timeout', prior_statement_timeout, true);
  IF coalesce(fenced, FALSE) THEN
    RETURN 'fenced';
  END IF;
  RETURN 'not-ready';
END;
$$;

CREATE OR REPLACE FUNCTION keiro.keiro_try_projection_promotion_lock_v1(
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
  prior_lock_timeout TEXT;
  prior_statement_timeout TEXT;
BEGIN
  remaining_ms := ceil(extract(epoch FROM (attempt_deadline - clock_timestamp())) * 1000);
  IF remaining_ms <= 0 THEN
    RETURN 'deadline-exceeded';
  END IF;
  prior_lock_timeout := current_setting('lock_timeout');
  prior_statement_timeout := current_setting('statement_timeout');
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
      PERFORM set_config('lock_timeout', prior_lock_timeout, true);
      PERFORM set_config('statement_timeout', prior_statement_timeout, true);
      RETURN 'deadline-exceeded';
  END;
  PERFORM set_config('lock_timeout', prior_lock_timeout, true);
  PERFORM set_config('statement_timeout', prior_statement_timeout, true);
  IF locked_run_id IS NOT NULL THEN
    RETURN 'locked';
  END IF;
  RETURN 'not-ready';
END;
$$;

CREATE OR REPLACE FUNCTION keiro.keiro_try_projection_relation_locks_v1(
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
  prior_lock_timeout TEXT;
  prior_statement_timeout TEXT;
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
  prior_lock_timeout := current_setting('lock_timeout');
  prior_statement_timeout := current_setting('statement_timeout');
  PERFORM set_config('lock_timeout', remaining_ms::text || 'ms', true);
  PERFORM set_config('statement_timeout', remaining_ms::text || 'ms', true);
  BEGIN
    EXECUTE 'LOCK TABLE ' || relation_list || ' IN ACCESS EXCLUSIVE MODE';
  EXCEPTION
    WHEN lock_not_available OR query_canceled THEN
      PERFORM set_config('lock_timeout', prior_lock_timeout, true);
      PERFORM set_config('statement_timeout', prior_statement_timeout, true);
      RETURN FALSE;
  END;
  PERFORM set_config('lock_timeout', prior_lock_timeout, true);
  PERFORM set_config('statement_timeout', prior_statement_timeout, true);
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION keiro.keiro_try_projection_cutover_fence_v1(TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION keiro.keiro_try_projection_promotion_lock_v1(TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION keiro.keiro_try_projection_relation_locks_v1(BIGINT[], TIMESTAMPTZ) FROM PUBLIC;
