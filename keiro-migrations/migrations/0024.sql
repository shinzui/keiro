-- projection rebuild slice fingerprints

-- Group identity becomes the group's own catalog slice; runs carry the slice
-- they were begun under for epoch-consistency joins. The run catalog
-- fingerprint remains begin-stamped provenance.
ALTER TABLE keiro.keiro_projection_rebuild_groups
  RENAME COLUMN catalog_fingerprint TO slice_fingerprint;

ALTER TABLE keiro.keiro_projection_rebuild_runs
  ADD COLUMN group_slice_fingerprint TEXT NOT NULL DEFAULT '$pre-canonical';

ALTER TABLE keiro.keiro_projection_rebuild_runs
  ALTER COLUMN group_slice_fingerprint DROP DEFAULT;
