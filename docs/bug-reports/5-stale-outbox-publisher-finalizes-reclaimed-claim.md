---
type: Bug Report
title: Stale outbox publisher finalizes another publisher's reclaimed claim
description: A publisher resumed after maintenance can mark a newly claimed outbox row failed or dead even after the new publisher reports success.
generated:
  by: process:codex
  at: "2026-09-24T19:09:18Z"
bugId: BUG-5
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou
affects: mori://shinzui/keiro
affectedVersion: "0.17.0.0"
environment: PostgreSQL 18 with durable settings; keiro 0.17.0.0; two publisher processes and one outbox maintenance pass.
observed: The first publisher is stopped after claiming a row. Maintenance requeues it and a second publisher claims and reports success. When the first publisher resumes, its late finalization changes the second publisher's publishing row to failed or dead; the second publisher's success cannot mark it sent.
expected: Finalization should affect only the claim owned by the finalizing publisher. A stale publisher must not change a newer claim, and a row reported successful by the current publisher should reach sent.
reproduction:
  - Build the released cohort used by mori://shinzui/keiro-runtime-kenshou and start durable PostgreSQL 18.
  - Run `nix develop -c cabal run kenshou -- run keiro/outbox/concurrency/zombie-publisher-finalization --dim pg.durability=durable --set outbox.zombie-outcome=failed --out runs/` from the Kenshou repository.
  - The scenario stops publisher P1 inside its callback, waits past the one-second publishing timeout, runs maintenance, and parks P2 after its broker append before resuming P1.
  - Inspect `schedule-realised`, `stale-finalization-no-effect`, and `terminal-consistent-with-success` verdicts. Repeat with `outbox.zombie-outcome=dead` and `outbox.zombie-outcome=succeeded`.
workaround: Keep publishingTimeout longer than the maximum expected callback duration and alert on long-running publishing rows. This reduces the overlap but does not fence a stale publisher after reclamation.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-24T19:09:51Z"
    document_timestamp: "2026-09-24T19:09:18Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: gpt-6-sol
    effort: medium
    context: Checked the report against all three durable zombie-publisher runs, the finalization SQL, and the bug-report profile.
---

# Stale outbox publisher finalizes another publisher's reclaimed claim

The Kenshou failed-outcome run `01a0d4d0-d80e-73df-a678-185c7d8bd738` realised the controlled schedule. P1's failed finalization changed P2's active claim from `publishing` to `failed`; P2 had already appended one broker record and later reported success, but the row remained `failed`. The dead-outcome run `01a0d4d2-4640-7008-9a09-e46104d73de9` left the row `dead` after P2's successful broker append. The succeeded-outcome control `01a0d4d1-e880-7794-b394-58223cac3e34` left the row `sent`, but P1 still finalized P2's claim. Run artifacts are under `mori://shinzui/keiro-runtime-kenshou` at `runs/<run-id>`; an artifact-level Mori URI for run directories is pending.

The finalization statements in `keiro/src/Keiro/Outbox/Schema.hs` guard only on `outbox_id` and `status = 'publishing'`. A maintenance requeue followed by a new claim returns the row to `publishing`, so a delayed statement from the old publisher matches the new claim. A claim generation or equivalent fencing value appears necessary; the report does not prescribe its implementation.
