-- keiro snapshots: fold-sensitive discriminator component (state shape hash).
--
-- Adds the third snapshot-compatibility column. Existing rows get the empty
-- string, which never equals a real hash, so every pre-existing snapshot is
-- treated as incompatible once: the next hydration falls back to full replay
-- and re-persists a seed carrying the real hash. Snapshots are advisory, so
-- this is a one-time replay cost, not a correctness event.
ALTER TABLE keiro.keiro_snapshots
  ADD COLUMN IF NOT EXISTS state_shape_hash TEXT NOT NULL DEFAULT '';
