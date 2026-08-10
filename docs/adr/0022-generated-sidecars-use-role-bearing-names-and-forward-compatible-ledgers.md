---
type: Architecture Decision Record
title: Generated sidecars use role-bearing names and forward-compatible ledgers
description: Keiro DSL names machine history as explicit-slot ledgers, names pasted build metadata as Cabal fragments, and migrates old names only through an explicit lossless apply step.
timestamp: 2026-08-10T02:00:37Z
docId: ADR-22
status: Accepted
date: 2026-08-05
---

# 22. Generated sidecars use role-bearing names and forward-compatible ledgers

Date: 2026-08-05

Status: Accepted


## Context

A scaffold run writes both machine-owned history and human-facing build guidance
beside generated Haskell. The historical names inverted those roles: files named
`record` were parsed on every later run, while files named `manifest` were only
Cabal text for a person to paste. The authored `.keiro-workspace` input was also
called a manifest, giving one word three incompatible meanings.

Renaming machine history without a migration would be destructive. An old-name
tree would look history-free, silencing stale, drift, and ownership-move evidence
and possibly reopening one-shot adoption. The conformance package also used a
stricter whitespace-split record format than workspace history: a future row
invalidated the whole file, and a legal relative path containing a space could
not round-trip.


## Decision

**Every generated sidecar name states its role.** Machine-read history uses the
`ledger` stem. Standalone and workspace histories occupy explicit literal slots:
`keiro-dsl-ledger.context.<context>.txt` and
`keiro-dsl-ledger.workspace.<service>.txt`. Conformance-package history is
`keiro-dsl-conformance-ledger.txt`. Human-pasted build metadata is named
`keiro-dsl-cabal-fragment.context.<context>.txt` or
`keiro-dsl-cabal-fragment.workspace.<service>.txt`. The authored
`.keiro-workspace` input remains the workspace manifest, and the one-shot
`keiro-dsl-migration-report.workspace.<service>.txt` keeps its accurate name.

The explicit `context` and `workspace` segments make the current ledger and Cabal
fragment namespaces disjoint by construction. `Ledger` also communicates the
operational contract: the file is machine-owned, committed when it represents a
committed scaffold history, not hand-edited, and never casually discarded.

**Old names migrate through a refusal and an explicit apply step.** If any old
sidecar is present, ordinary scaffolding lists the required moves and writes
nothing. `scaffold --apply-name-migrations` performs the reviewed moves. An
old-only file is renamed; when both old and current names exist, the current file
remains authoritative and the old bytes are retired under
`.keiro-dsl-name-migrations/sidecar-v1/`. A pre-existing retirement destination
is a conflict rather than overwrite authority. Repeating the migration plans no
further move.

Adoption is the sole permanent legacy-reading path: it searches current context
history first, then its historical record name, and appends `superseded-by:` to
the file it actually adopted. Sidecar name migration never writes that marker;
it continues to mean only that context history was imported into workspace
history.

**Every machine-read sidecar has an extension-tolerant durability contract.** The
conformance ledger begins with `keiro-dsl conformance ledger v1`, retains its
service-key, runtime-package, and facade-module scalar rows, and represents files
as typed rows with single-line JSON payloads. Unknown row kinds and unknown JSON
keys are ignored. Known rows still reject corruption, unsafe relative paths,
case-folded duplicate paths, and a service-key mismatch. A historical
conformance record is parsed and converted only during the explicit migration;
its original bytes are preserved in the retirement slot.

Standalone and workspace scaffold ledgers additionally carry at most one
`semantic-impact` row with a canonical single-line JSON payload. Unknown row
kinds and unknown JSON object keys remain ignorable. A present known row is
strict: duplicate declaration keys, duplicate aggregate consumers, duplicate
service-inventory entries, disagreement between declaration rows and the
inventory, or malformed declaration identities invalidate the ledger before any
scaffold write. Every current writer emits the row, including for an empty mapped
inventory. Absence is therefore reserved for pre-feature history and means
“baseline unavailable,” not “no mapped impact.”


## Consequences

- A filename alone distinguishes machine-owned history from human-facing build
  guidance and authored workspace input.
- Existing output cannot silently present as fresh after an upgrade. Operators
  receive a complete, reviewable move list before any write.
- Duplicate historical evidence is retained without weakening the current
  ledger's authority or overwriting prior backups.
- Future conformance-ledger extensions do not break older readers merely because
  they add a row kind or JSON key, while invalid known data remains a refusal.
- Semantic-impact history extends the same rule: old readers ignore the new row,
  current readers distinguish absent legacy evidence from a present empty
  inventory, and corrupted known evidence refuses before generation.
- `Refusal`, `ScaffoldReport`, and `WorkspaceScaffoldReport` gain public sidecar
  migration surfaces, so exhaustive library consumers must update.


## Alternatives considered

**Use a `lock` stem.** Rejected because ecosystem lockfiles are conventionally
regenerable. Deleting these files destroys ownership and drift history, so
`lock` would encourage the wrong recovery action.

**Distinguish context and workspace by segment count.** Rejected because literal
slot segments make collision-freedom visible and structural instead of depending
on a written parsing argument.

**Silently read old names and append `superseded-by:`.** Rejected because an
explicit refusal proves the old tree cannot be mistaken for fresh, handles the
both-names-present case, leaves no misleading old-name file in the active tree,
and preserves the adoption marker's single meaning.

**Keep the old conformance format during the rename.** Rejected because the
rename already creates the compatibility boundary; converting once in that
window avoids a second migration while aligning all machine history with the
same forward-compatibility rule.


## Related decisions

- ADR 0015 defines workspace-keyed history, per-module attribution, and adoption.
- ADR 0019 defines the generated-name migration rail reused by sidecars.
- ADR 0020 defines the runnable service conformance package whose ledger follows
  this durability contract.
- [Plan 198](../plans/198-rename-keiro-dsl-sidecars-to-explicit-slot-ledger-names-with-one-durability-contract.md)
  implements this decision and closes
  [IR-19](../improvement-requests/give-keiro-dsl-generated-sidecars-honest-names-and-one-durability-contract.md).
