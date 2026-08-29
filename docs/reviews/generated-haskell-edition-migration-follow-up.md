---
type: Review
title: Generated Haskell edition migration follow-up
description: Every recorded pre-current edition is now refused before generated writes, legacy name and edition adoption composes under both flags with exact backups, unreadable ledgers fail closed, and the documented recovery path is regression-tested.
generated:
  by: process:codex
  at: "2026-08-29T15:05:46Z"
reviewId: REV-16
subject: mori://shinzui/keiro
subjectKind: component
component: Keiro.Dsl.ScaffoldRun.preflightGeneratedHaskellEditionMigration
reviewedSha: 4f13131264594b200b7fc752728bc2b458685edf
coverage: full
reviewedAt: "2026-08-29T15:05:46Z"
reviewerKind: model
reviewer: process:codex
provider: openai
model: gpt-5
effort: high
outcome: approved
dimensions:
  - correctness
  - operability
  - test-coverage
  - documentation
context: >-
  Re-reviewed every finding and follow-up in REV-14 against the single-file
  and workspace preflight/apply paths, ledger parsers, refusal rendering,
  lexical Hole scanner, presentation rewriter, user and adoption documents,
  and focused Hspec coverage; then drove the reviewed binary through the
  released 0.14.0.0 cold-start corpus with missing-edition, legacy-sidecar,
  combined-apply, rerun, backup-byte, and malformed-ledger probes before
  running the complete repository gate.
---

# Generated Haskell edition migration follow-up

## Release verdict

Approved. The release-blocking gap from REV-14 is closed. A parsed ledger at
any edition other than `idiomatic-v2` now enters the generated-edition
preflight in both scaffold paths; a missing edition row is parsed as
`legacy-v1` and can no longer be rewritten as a fresh tree. A present ledger
that does not parse is a distinct fail-closed refusal before generated or
sidecar writes.

The realistic legacy path is one explicit operation. Old sidecars may be
renamed first, but a run that has name-migration work—source moves or just
those sidecar renames—requires both `--apply-name-migrations` and
`--apply-generated-haskell-edition` before edition adoption. The edition
backup is taken before source moves, retains every recorded existing file
byte-for-byte under a from-edition-specific root, and the remediation report
lists the source moves needed for rollback. Single-file and workspace paths
have equivalent regression coverage, including the released-corpus shape in
which historical and current Hole paths coexist and only sidecars need moving.

The remaining REV-14 correctness and recovery findings are also resolved.
The Hole scan labels prefix, qualified, renamed record-dot, record-field, and
operator-operand uses while stating everywhere that its results are
attributable rather than complete. Comments and unchanged labels are negative
cases. The remediation report is regenerated on apply and is no longer
conflict evidence, so restore, edit, and retry converges without deleting it;
byte-identical backups remain the safety boundary. Tampered backups,
interrupted application, unreadable ledgers, rollback and retry, and the real
CLI boundary all have executable examples.

Finally, the presentation rewriter no longer mistakes Template Haskell name
quotes, promoted ticks, or symbolic dash runs for unterminated literals or
comments. Its observable end-state test finishes every tracked Generated
module in `Code`, and full corpus regeneration is byte-neutral. The user
reference, adoption guide, downstream audit, changelogs, and ADRs 15 and 19
now describe the same shipped protocol. No correctness, operability, coverage,
or documentation blocker remains for this migration at the reviewed commit.

## Evidence

- The focused `Haskell.name-migration` group passes 5 examples, including the
  sidecar-only legacy shape in both scaffold paths. The generated-edition group
  passes 7 examples, and the presentation-rewriter group passes 2 examples.
- The released-corpus no-row probe exits 1 with
  `legacy-v1 -> idiomatic-v2`, no migration directory, and an unchanged tree.
  With legacy sidecar names, name-only exits 1 and prints the combined-flags
  guidance; both flags exit 0, writes `naming-edition idiomatic-v2`, and a
  second identical run changes no bytes.
- Every file under
  `.keiro-dsl-generated-haskell-migrations/legacy-v1-to-idiomatic-v2/` in the
  scratch apply matches its pre-apply byte source; the report records
  `source-moves: 0` for the released corpus's already-present destinations.
- Appending a duplicate `spec:` row makes the CLI exit 1 with `scaffold ledger
  ... could not be parsed`, and the complete scratch tree hash is unchanged.
- `just corpus-regen` selects 39 of 39 invocations and reports zero tracked
  changes. The record inventory generator/check, extension policy, and
  formatter all exit 0.
- The final `just verify` run exits 0 at
  `4f13131264594b200b7fc752728bc2b458685edf`: the main DSL suite reports 720
  examples and zero failures, the core suite 620 and zero, PGMQ 58 and zero
  with its two expected pending cases, ops 48 and zero, integration 25 and
  zero, and migrations 35 and zero. All documentation and assurance bundles,
  generated-name policy, diagrams, and the conformance corpus pass.

## Non-blocking boundary

The Hole inventory deliberately remains a lexical, attributable-only aid; a
successful consumer compile remains authoritative for forms outside its
documented coverage. This is now stated in both refusal and report output and
does not weaken the fail-closed ledger or byte-backup protocol.
