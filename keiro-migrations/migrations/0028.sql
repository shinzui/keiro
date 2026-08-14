-- permit implementation-backed compatibility wrappers with stable zero-argument signatures

ALTER TABLE keiro.keiro_external_read_contracts
  DROP CONSTRAINT keiro_external_read_contracts_implementation_chk,
  ADD CONSTRAINT keiro_external_read_contracts_implementation_chk
    CHECK (
      (
        contract_kind = 'all-rows'
        AND cardinality(argument_names) = 0
        AND private_implementation IS NULL
        AND private_implementation_version IS NULL
      )
      OR (
        contract_kind = 'keyed'
        AND private_implementation IS NOT NULL
        AND length(private_implementation) > 0
        AND private_implementation_version > 0
      )
    );

COMMENT ON CONSTRAINT keiro_external_read_contracts_implementation_chk
  ON keiro.keiro_external_read_contracts IS
  'All-row contracts are Keiro-backed; keyed contracts delegate to a versioned consumer implementation and may retain a zero-argument public compatibility signature.';
