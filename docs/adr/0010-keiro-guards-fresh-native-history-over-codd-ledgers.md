# 3. Keiro guards fresh native history over codd ledgers

Date: 2026-07-23

Status: Accepted


## Context

Keiro's one-time production cutovers import applied codd history into pg-migrate before
running the native plan. pg-migrate correctly treats every declared migration as pending
when its native ledger is absent. It does not know that a codd ledger is transition
evidence, and its reusable CLI runs `up` directly.

Running `up` first is recoverable but operationally dangerous. Against current codd
history, Kiroku migrations 0001 through 0005 commit audit-less native rows before
migration 0006 encounters an already-present constraint. The codd importer then rejects
those rows because they lack matching import audits. Against older codd history and the
`0.1.0.0` Keiro layout, the native plan can instead succeed and create empty parallel
`keiro.*` tables while the real rows remain under `kiroku`.

The pg-migrate runner acquires its advisory lock inside a private module. Its public event
handler has no connection, and `ConnectionProvider` is intentionally opaque. Adding a
generic in-lock pre-apply hook would require a coordinated pg-migrate family release.


## Decision

Keiro performs a read-only preflight immediately before dispatching `keiro-migrate up`.
The preflight checks for either `codd.sql_migrations` or
`codd_schema.sql_migrations` and for `pgmigrate.migrations`.

It blocks exactly when a codd ledger exists and the native migrations table is absent or
contains zero rows. A populated native ledger clears the preflight: a completed import
must permit `up`, while a poisoned ledger already fails through pg-migrate's own
history-conflict semantics and has a separately documented recovery procedure.

The preflight accepts Hasql connection settings and brackets a dedicated connection. It
does not import pg-migrate runner internals. The CLI resolves settings with the same
precedence as `up`: the command's `--database-url` overrides `DATABASE_URL`.

`--allow-fresh-ledger-over-codd` bypasses the refusal only for `up` and is rejected with
every other command. It exists for a deliberate fresh native ledger over a retired codd
table, never for a normal cutover.

Keiro also owns the cutover command:
`keiro-migrate import-codd-history --reason TEXT --confirm`. It always uses the compiled-in
combined Kiroku/Keiro mappings and strict source mode. Target and source connection
settings may differ, and the source advisory lock key is configurable for coordination
with the legacy wrapper.

The check runs before pg-migrate's advisory lock. This check-before-lock interval is
accepted because the hazardous codd ledger is pre-existing production state, not an
object a concurrent native runner creates. The runbook separately requires all
application and legacy migration writers to be quiescent.


## Consequences

An ordinary `up` can no longer initialize empty native history over an existing codd
ledger. The refusal names the detected table, points to the cutover runbook, and exits
before pg-migrate creates or mutates its ledger.

Operators have one tested, idempotent import path instead of bespoke Haskell. Missing
sentinel filename realignment, strict-source extras, absent confirmation, and poisoned
native rows remain fail-safe structured errors.

The preflight is intentionally Keiro-specific. Kiroku's standalone migration executable
has the same class of unguarded path and needs a parity change in its own repository.

Recovery can require `DROP SCHEMA pgmigrate CASCADE`, and the older parallel-schema
variant can require dropping an empty `keiro` schema. Both operations are documented only
behind explicit row and audit preconditions and are proven against ephemeral databases in
the default migration suite.


## References

- [docs/plans/124-guard-up-against-codd-ledgered-databases-and-mount-the-codd-import-in-the-cli.md](../plans/124-guard-up-against-codd-ledgered-databases-and-mount-the-codd-import-in-the-cli.md)
  — implementation plan, dependency analysis, manual transcripts, and recovery evidence.
- [docs/masterplans/19-restore-the-migration-integrity-gates-under-pg-migrate-surfaced-by-the-2026-07-migration-review.md](../masterplans/19-restore-the-migration-integrity-gates-under-pg-migrate-surfaced-by-the-2026-07-migration-review.md)
  — initiative scope and the review findings this policy closes.
- [docs/user/upgrading-to-the-keiro-schema.md](../user/upgrading-to-the-keiro-schema.md)
  — operator cutover, sentinel realignment, and guarded recovery procedure.
