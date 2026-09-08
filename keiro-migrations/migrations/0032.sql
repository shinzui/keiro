-- add guarded timer resume leases
ALTER TABLE keiro.keiro_timers
  ADD COLUMN resume_claim_token UUID,
  ADD COLUMN resume_lease_until TIMESTAMPTZ,
  ADD CONSTRAINT keiro_timers_resume_ownership CHECK (
    (resume_claim_token IS NULL AND resume_lease_until IS NULL)
    OR (resume_claim_token IS NOT NULL AND resume_lease_until IS NOT NULL AND status = 'firing')
  );
