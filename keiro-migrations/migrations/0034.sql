-- add stored workflow inspection class and key index
-- Stored derivation preserves HOT eligibility when repeated retry increments
-- leave the class unchanged. A direct expression index on attempts does not.
-- This rewrites the table and takes a write-blocking lock; apply in maintenance.
ALTER TABLE keiro.keiro_workflows
  ADD COLUMN inspection_status_class text GENERATED ALWAYS AS (
    CASE
      WHEN status = 'running' AND attempts = 0 THEN 'running'
      WHEN status = 'running' THEN 'retrying'
      WHEN status = 'suspended' AND wake_after IS NOT NULL THEN 'sleeping'
      WHEN status = 'suspended' THEN 'awaiting'
      ELSE status
    END
  ) STORED;

CREATE INDEX keiro_workflows_inspection_class_key_idx
  ON keiro.keiro_workflows (inspection_status_class, workflow_name, workflow_id)
  WHERE octet_length(workflow_name) + octet_length(workflow_id) <= 2600;

-- Fixed-width access preserves valid large keys. Hashes locate candidates;
-- readers recheck full text and cap exceptional work before sorting/returning.
CREATE INDEX keiro_workflows_inspection_wide_idx
  ON keiro.keiro_workflows (
    inspection_status_class,
    hashtextextended(workflow_name, 0),
    hashtextextended(workflow_id, 0)
  )
  WHERE octet_length(workflow_name) + octet_length(workflow_id) > 2600;
