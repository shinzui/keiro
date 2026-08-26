---
type: Review
title: Generated Haskell edition migration to idiomatic-v2
description: The explicit idiomatic-v1 adoption path refuses before writing, backs up the recorded tree, and is idempotent, but ledgers without an edition row skip the gate entirely and the user reference does not know the flag exists.
generated:
  by: process:claude-code
  at: "2026-08-26T23:38:11Z"
reviewId: REV-14
subject: mori://shinzui/keiro
subjectKind: component
component: Keiro.Dsl.ScaffoldRun.preflightGeneratedHaskellEditionMigration
reviewedSha: acb9ee6cca88dd2ab6db5f6a3ff80b788e8e5d21
coverage: full
reviewedAt: "2026-08-26T23:38:11Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: high
outcome: changes-requested
dimensions:
  - correctness
  - operability
  - test-coverage
  - documentation
context: >-
  Read the preflight, apply, and refusal code in ScaffoldRun and
  WorkspaceScaffold, the ledger parsers, the CLI wiring, the lexical
  presentation rewriter, the Hspec group that covers them, the adoption guide,
  and the user reference; then drove the keiro-dsl binary built at the
  reviewed commit through fourteen live scenarios against the 0.14.0.0
  conformance corpus (refusal, apply, rerun, interrupted apply, tampered
  backup, rollback and retry, missing and malformed ledgers, legacy sidecar
  names, workspace parity, and Hole scanner probes) in a scratch copy.
---

# Generated Haskell edition migration to idiomatic-v2

## Release verdict

Changes requested. The path the guide describes works as promised for a ledger
that records `naming-edition idiomatic-v1`: ordinary scaffolding exits non-zero
before any write and lists every recorded Generated path, both sidecars, and the
attributable Hole uses it can see; `--apply-generated-haskell-edition` copies
each existing recorded file byte-for-byte under
`.keiro-dsl-generated-haskell-migrations/idiomatic-v1-to-idiomatic-v2/`, writes
the remediation report, never touches a create-once Hole, and installs the v2
ledger only after every generated write; a rerun is byte-idempotent; a
mid-apply crash is refused on rerun with one conflict line per diverged file;
and restoring the backed-up set and rerunning converges on the same tree hash
as a clean apply. The workspace path follows the same protocol.

Two things must be resolved before the tag, because the release notes make a
promise the tool does not keep and the user reference contradicts the tool.

1. **Ledgers without a `naming-edition` row bypass the gate.** Both ledger
   parsers map a missing row to `LegacyNamingV1`
   (`ScaffoldRecord.parseNamingEdition`, `WorkspaceRecord.parseNamingEdition`),
   the preflight gates only `Just IdiomaticNamingV1`
   (`ScaffoldRun.preflightGeneratedHaskellEditionMigration`), and the record
   writers stamp `currentGeneratedHaskellNamingEdition`, which is
   `IdiomaticNamingV2`. A legacy tree therefore goes straight to v2 on its
   next successful scaffold with no backup, no Hole scan, and no report. In
   the realistic pre-0.11 shape (legacy sidecar names, no row) the only gate
   is `sidecar migration required`, and `--apply-name-migrations` alone
   completes the jump. The downstream audit places three of the six
   generated-API consumers (`danwa`, `keiro-runtime-jitsurei`, `kotei`) in
   exactly this state, and the root changelog's "existing scaffold ledgers
   require explicit, backup-backed adoption" is false for them. Either extend
   the preflight to every recorded pre-v2 edition and let the two apply flags
   compose in one run (today the guard that refuses an edition migration with
   pending source moves points the user at `--apply-name-migrations`, which
   cannot satisfy it), or narrow the changelog and guide to ledgers that
   record `idiomatic-v1` and tell the three legacy consumers to adopt from a
   clean checkout.
2. **The user reference does not describe the new refusal.**
   `docs/user/typed-spec-toolchain.md` still says "The one source-moving
   exception is an upgrade from a recorded legacy generated-name edition",
   documents only `--apply-name-migrations`, and describes the Cabal fragment
   without the four record defaults. It never mentions
   `--apply-generated-haskell-edition`, `idiomatic-v2`, or the `generated
   Haskell edition migration required` refusal that every existing scaffolded
   consumer will meet on its first scaffold after upgrading. The adoption
   guide is correct but is not where a reader of the refusal is sent.

## Should fix, not tag-blocking

- **A malformed ledger silently disables the gate.** `readRecord` returns
  `Nothing` for both a missing and an unparseable ledger, and the ledger
  parser is strict (duplicate rows, a `semantic-contract` that does not equal
  the recomputed contract). A ledger with one duplicated `spec:` row was
  treated as a fresh scaffold: exit 0, ten modules overwritten, ledger
  rewritten as v2, no diagnostic. Any future format drift converts the hard
  refusal into a silent overwrite; distinguish "absent" from "present but
  unreadable" and refuse the latter.
- **The Hole scanner misses the forms that actually break under v2.**
  `selectorApplication` reports only an unqualified prefix application
  followed by an identifier or parenthesis. It rejects `M.failureCode x`,
  `f.failureCode` (record-dot on a renamed label, the very idiom the guide
  recommends for dual-edition code, which fails under v2 because the label is
  now `code`), `f {failureCode = ...}`, puns, `failureCode <$> ...`, and
  multi-line application, and it does not exclude comments or strings. Five
  probe forms in a Hole yielded `hand-owned selector uses: 1`. The guide
  carries the "attributable, not complete" caveat; the refusal text and the
  report print a bare count without it.
- **Retry after rollback refuses on the stale remediation report.**
  `checkReport` treats a differing `remediation-report.txt` as a hard
  conflict, the report is not part of the backup set, and the guide's
  rollback section does not mention it. Restoring the backed-up set, fixing
  the reported Hole use, and rerunning the apply is refused with `edition
  remediation report conflict` until the report is deleted by hand. Regenerate
  the report instead of refusing, or add it to the rollback instructions.

## Follow-ups

- Conflict and tamper detection exist only while the ledger still records
  `idiomatic-v1`; once it flips, a tampered backup or a Generated file
  restored to v1 bytes is silently overwritten. The guide's "continues or
  refuses" sentence should state that condition.
- The backup set is the ledger-recorded files only. A conformance package's
  `Main.hs`, `.cabal`, and package ledger are written after the record and are
  not backed up, so the guide's "every existing Generated file" overstates.
- `modernizeGeneratedHaskellSource` enters its character-literal state on
  Template Haskell name quotes (`''XCommand`) and promoted ticks (`'[]`), and
  treats `--` inside an operator as a comment. Re-implementing its state
  machine over all 487 Generated modules of the 0.14 corpus leaves 54 Domain
  modules desynchronised at end of file; no label token follows a
  desynchronisation point today, so the corpus is correct, but the next entry
  added to `idiomaticV2LabelMigrations` can be silently skipped in those
  modules. The rewriter also rewrites every identifier token, not only record
  labels.
- The frozen `conformance-skeletons` corpus records `naming-edition
  idiomatic-v1` and an `OverloadedStrings`-only fragment while its Generated
  modules were hand-migrated to v2 syntax; nothing reads those sidecars, but
  it is the mixed state the guide forbids and the only v1 ledger left.
- Test coverage stops at the happy path. `keiro-dsl/test/Main.hs` covers
  refusal without mutation, ledger backup, Hole preservation, rerun, and the
  workspace protocol; nothing exercises `GeneratedHaskellEditionRefusal` (a
  backup or report conflict), an interrupted apply, the legacy-v1 path, or a
  scanner negative. Every defect above sits in an untested branch.

## Evidence

- Binary: `cabal list-bin keiro-dsl` after `cabal build all` exited 0 at the
  reviewed commit. Fixture: `git archive keiro-0.14.0.0 keiro-dsl/test`
  extracted per scenario; the `subscription.keiro` coldstart context for the
  single-file path and `conformance-service-package` for the workspace path.
- Ordinary scaffold over the 0.14 `idiomatic-v1` ledger exited 1 with the
  tree hash unchanged and a refusal listing eleven Generated paths and two
  sidecars; `--force-generated-overwrite` and `--apply-name-migrations` did
  not bypass it.
- `--apply-generated-haskell-edition` produced eleven `.hs` and two sidecar
  backups byte-identical to the 0.14 tree, the report, and a v2 ledger; the
  Hole's SHA-256 was unchanged across every step; the rerun with and without
  the flag was byte-idempotent.
- One Generated file restored to v1 bytes under a v1 ledger: rerun refused
  with five `edition backup conflict` lines and no writes; a full restore and
  rerun exited 0 with the same tree hash as the clean apply. A tampered
  backup under a v1 ledger was refused naming the file.
- Rollback followed by a Hole fix and a retry: exit 1, `edition remediation
  report conflict`; exit 0 only after deleting the report.
- Ledger with the `naming-edition` row deleted: ordinary scaffold exited 0,
  overwrote ten modules, wrote `naming-edition idiomatic-v2`, and created no
  backup directory. Same result for a ledger with a duplicated `spec:` row.
  Legacy sidecar names without a row: no flags refused with `sidecar
  migration required`; `--apply-name-migrations` alone exited 0 with a v2
  ledger and no backup.
- Workspace path: refusal listing 27 Generated paths and two sidecars with no
  writes; apply produced 29 backups and the report; rerun idempotent.
- Five Hole probe forms (`failureCode f`, `BC.failureCode f`, `f.failureCode`,
  `f {failureCode = "x"}`, `failureCode <$> fs`) produced `hand-owned
  selector uses: 1`.
- `keiro-dsl/test/Main.hs` group "generated Haskell edition migration": two
  examples, single-file and workspace, both passing.
- `just verify` exited 0 at the reviewed commit (started 2026-08-26T23:26:22Z, finished 23:40:13Z): 49 of 49 test suites passed with zero failures, including 712 `keiro-dsl-test` and 620 `keiro-test` examples, the jitsurei walkthrough and diagram check, the conformance-corpus replay check (39 of 39, frozen skeleton corpus verified only), the extension and generated-name policies, and `keiro-migrations-test`.
