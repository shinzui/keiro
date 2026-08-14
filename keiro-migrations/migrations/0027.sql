-- managed external read contracts

CREATE TABLE keiro.keiro_external_read_contracts (
  contract_id TEXT NOT NULL,
  contract_version INTEGER NOT NULL,
  query_model_id TEXT NOT NULL,
  group_id TEXT NOT NULL
    REFERENCES keiro.keiro_projection_rebuild_groups (group_id),
  public_function_name TEXT NOT NULL,
  contract_kind TEXT NOT NULL,
  argument_names TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  argument_types TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  result_type TEXT NOT NULL,
  result_shape_hash TEXT NOT NULL,
  serving_shape_hash TEXT,
  compatible_revision_ids TEXT[] NOT NULL,
  private_implementation TEXT,
  private_implementation_version INTEGER,
  immutable_signature_hash TEXT NOT NULL,
  definition_hash TEXT NOT NULL,
  surface_generation INTEGER NOT NULL,
  state TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  retired_at TIMESTAMPTZ,
  PRIMARY KEY (contract_id, contract_version),
  UNIQUE (public_function_name, argument_types),
  CONSTRAINT keiro_external_read_contracts_identity_chk
    CHECK (
      length(contract_id) > 0
      AND contract_version > 0
      AND length(query_model_id) > 0
      AND length(group_id) > 0
      AND length(public_function_name) > 0
      AND length(result_type) > 0
      AND length(result_shape_hash) > 0
      AND length(immutable_signature_hash) > 0
      AND length(definition_hash) > 0
      AND surface_generation > 0
      AND cardinality(compatible_revision_ids) > 0
      AND array_position(compatible_revision_ids, NULL) IS NULL
      AND array_position(argument_names, NULL) IS NULL
      AND array_position(argument_types, NULL) IS NULL
      AND cardinality(argument_names) = cardinality(argument_types)
    ),
  CONSTRAINT keiro_external_read_contracts_kind_chk
    CHECK (contract_kind IN ('all-rows', 'keyed')),
  CONSTRAINT keiro_external_read_contracts_implementation_chk
    CHECK (
      (
        contract_kind = 'all-rows'
        AND cardinality(argument_names) = 0
        AND private_implementation IS NULL
        AND private_implementation_version IS NULL
      )
      OR (
        contract_kind = 'keyed'
        AND cardinality(argument_names) > 0
        AND private_implementation IS NOT NULL
        AND length(private_implementation) > 0
        AND private_implementation_version > 0
      )
    ),
  CONSTRAINT keiro_external_read_contracts_state_chk
    CHECK (state IN ('candidate', 'active', 'pending-retirement', 'retired')),
  CONSTRAINT keiro_external_read_contracts_retired_chk
    CHECK (
      (state = 'retired' AND retired_at IS NOT NULL)
      OR (state <> 'retired' AND retired_at IS NULL)
    )
);

CREATE INDEX keiro_external_read_contracts_group_idx
  ON keiro.keiro_external_read_contracts (group_id, state);

CREATE TABLE keiro.keiro_managed_read_objects (
  object_schema TEXT NOT NULL,
  object_name TEXT NOT NULL,
  object_kind TEXT NOT NULL,
  object_signature TEXT NOT NULL DEFAULT '',
  contract_id TEXT,
  contract_version INTEGER,
  managed_by TEXT NOT NULL,
  definition_hash TEXT NOT NULL,
  surface_generation INTEGER NOT NULL,
  state TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  retired_at TIMESTAMPTZ,
  PRIMARY KEY (object_schema, object_name, object_kind, object_signature),
  FOREIGN KEY (contract_id, contract_version)
    REFERENCES keiro.keiro_external_read_contracts (contract_id, contract_version),
  CONSTRAINT keiro_managed_read_objects_identity_chk
    CHECK (
      length(object_schema) > 0
      AND length(object_name) > 0
      AND length(object_kind) > 0
      AND length(managed_by) > 0
      AND length(definition_hash) > 0
      AND surface_generation > 0
      AND (
        (contract_id IS NULL AND contract_version IS NULL)
        OR (contract_id IS NOT NULL AND contract_version IS NOT NULL)
      )
    ),
  CONSTRAINT keiro_managed_read_objects_kind_chk
    CHECK (object_kind IN ('guard-function', 'binding-view', 'wrapper-function', 'contract-type')),
  CONSTRAINT keiro_managed_read_objects_owner_chk
    CHECK (managed_by IN ('keiro', 'consumer')),
  CONSTRAINT keiro_managed_read_objects_state_chk
    CHECK (state IN ('active', 'pending-retirement', 'retired')),
  CONSTRAINT keiro_managed_read_objects_retired_chk
    CHECK (
      (state = 'retired' AND retired_at IS NOT NULL)
      OR (state <> 'retired' AND retired_at IS NULL)
    )
);

CREATE INDEX keiro_managed_read_objects_contract_idx
  ON keiro.keiro_managed_read_objects (contract_id, contract_version);

CREATE FUNCTION keiro_read.guard_external_read_v1(
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
BEGIN
  SELECT
    contracts.group_id,
    contracts.state,
    contracts.result_shape_hash,
    contracts.serving_shape_hash,
    contracts.compatible_revision_ids
  INTO
    contract_group_id,
    contract_state,
    contract_shape_hash,
    contract_serving_shape_hash,
    contract_compatible_revisions
  FROM keiro.keiro_external_read_contracts AS contracts
  WHERE contracts.contract_id = requested_contract_id
    AND contracts.contract_version = requested_contract_version;

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

  SELECT groups.reads_allowed, groups.serving_revision_id
  INTO group_reads_allowed, group_serving_revision
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

INSERT INTO keiro.keiro_managed_read_objects
  (object_schema, object_name, object_kind, object_signature,
   managed_by, definition_hash, surface_generation, state)
VALUES
  ('keiro_read', 'guard_external_read_v1', 'guard-function', 'text,integer',
   'keiro', 'migration-0027', 1, 'active');

COMMENT ON TABLE keiro.keiro_external_read_contracts IS
  'Private lifecycle and compatibility metadata for versioned external read functions.';
COMMENT ON TABLE keiro.keiro_managed_read_objects IS
  'Object-level ownership, generation, and definition hashes for reconciled external read surfaces.';
COMMENT ON FUNCTION keiro_read.guard_external_read_v1(TEXT, INTEGER) IS
  'Shared-lock availability and serving-revision compatibility guard for managed external reads.';
