# Wide-id workflow probe: rejected fixture

The proposed 2700-character workflow id passes the workflow row's existing key
constraints but fails Kiroku's stream-name length check during the first named
step, before any measurement file is written. This is not a writer performance
result. Preserve the failed fixture and sources; use a value within the released
journal naming contract for full workflow measurements, and keep large-row
storage compatibility evidence separate from executable workflow evidence.
