-- make guarded external reads revalidate contract state after the lifecycle lock

CREATE OR REPLACE FUNCTION keiro_read.guard_external_read_v1(
  requested_contract_id TEXT,
  requested_contract_version INTEGER
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $guard$
DECLARE
  contract_group_id TEXT;
  contract_state TEXT;
  contract_shape_hash TEXT;
  contract_serving_shape_hash TEXT;
  contract_compatible_revisions TEXT[];
  group_reads_allowed BOOLEAN;
  group_serving_revision TEXT;
  group_serving_epoch_before BIGINT;
  group_serving_epoch BIGINT;
BEGIN
  -- Contract-to-group ownership is immutable. Read only that routing fact before
  -- locking, then re-read every mutable contract fact after the group lock.
  SELECT contracts.group_id, groups.serving_epoch
  INTO contract_group_id, group_serving_epoch_before
  FROM keiro.keiro_external_read_contracts AS contracts
  JOIN keiro.keiro_projection_rebuild_groups AS groups
    ON groups.group_id = contracts.group_id
  WHERE contracts.contract_id = requested_contract_id
    AND contracts.contract_version = requested_contract_version;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'KR002',
      MESSAGE = 'external read contract is unknown or retired',
      DETAIL = pg_catalog.format(
        'contract=%s version=%s',
        requested_contract_id,
        requested_contract_version
      );
  END IF;

  SELECT groups.reads_allowed, groups.serving_revision_id, groups.serving_epoch
  INTO group_reads_allowed, group_serving_revision, group_serving_epoch
  FROM keiro.keiro_projection_rebuild_groups AS groups
  WHERE groups.group_id = contract_group_id
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'KR002',
      MESSAGE = 'external read contract group is unavailable',
      DETAIL = pg_catalog.format(
        'group=%s contract=%s version=%s',
        contract_group_id,
        requested_contract_id,
        requested_contract_version
      );
  END IF;

  -- A promotion updates the group and reconciles this row in one transaction.
  -- The locking re-read observes that committed row after waiting for promotion,
  -- rather than retaining the statement's pre-promotion metadata snapshot.
  SELECT
    contracts.state,
    contracts.result_shape_hash,
    contracts.serving_shape_hash,
    contracts.compatible_revision_ids
  INTO
    contract_state,
    contract_shape_hash,
    contract_serving_shape_hash,
    contract_compatible_revisions
  FROM keiro.keiro_external_read_contracts AS contracts
  WHERE contracts.contract_id = requested_contract_id
    AND contracts.contract_version = requested_contract_version
    AND contracts.group_id = contract_group_id
  FOR SHARE;

  IF NOT FOUND OR contract_state IN ('pending-retirement', 'retired') THEN
    RAISE EXCEPTION USING
      ERRCODE = 'KR002',
      MESSAGE = 'external read contract is unknown or retired',
      DETAIL = pg_catalog.format(
        'contract=%s version=%s',
        requested_contract_id,
        requested_contract_version
      );
  END IF;

  -- PostgreSQL fixes the caller statement snapshot before entering this
  -- function. A locking read can observe the newly committed group row after
  -- waiting, but the later projection query cannot safely adopt every catalog
  -- and relation change in that old snapshot. Refuse the crossed epoch so the
  -- caller retries as a new statement instead of returning stale or empty data.
  IF group_serving_epoch IS DISTINCT FROM group_serving_epoch_before THEN
    RAISE EXCEPTION USING
      ERRCODE = 'KR001',
      MESSAGE = 'projection generation changed while the external read waited',
      DETAIL = pg_catalog.format(
        'group=%s contract=%s version=%s serving_epoch_before=%s serving_epoch=%s',
        contract_group_id,
        requested_contract_id,
        requested_contract_version,
        group_serving_epoch_before,
        group_serving_epoch
      );
  END IF;

  IF NOT group_reads_allowed THEN
    RAISE EXCEPTION USING
      ERRCODE = 'KR001',
      MESSAGE = 'projection is temporarily unavailable',
      DETAIL = pg_catalog.format(
        'group=%s contract=%s version=%s serving_revision=%s',
        contract_group_id,
        requested_contract_id,
        requested_contract_version,
        coalesce(group_serving_revision, '<none>')
      );
  END IF;

  IF contract_state <> 'active'
     OR group_serving_revision IS NULL
     OR NOT (group_serving_revision = ANY(contract_compatible_revisions))
     OR contract_serving_shape_hash IS DISTINCT FROM contract_shape_hash THEN
    RAISE EXCEPTION USING
      ERRCODE = 'KR003',
      MESSAGE = 'external read contract is incompatible with the serving revision',
      DETAIL = pg_catalog.format(
        'group=%s contract=%s version=%s serving_revision=%s',
        contract_group_id,
        requested_contract_id,
        requested_contract_version,
        coalesce(group_serving_revision, '<none>')
      );
  END IF;
END
$guard$;

REVOKE ALL ON FUNCTION keiro_read.guard_external_read_v1(TEXT, INTEGER) FROM PUBLIC;

COMMENT ON FUNCTION keiro_read.guard_external_read_v1(TEXT, INTEGER) IS
  'Shared-lock availability, post-lock contract revalidation, and crossed-epoch retry fencing for managed external reads.';
