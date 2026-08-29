---
id: 268
slug: gate-every-pre-v2-generated-haskell-edition-and-harden-idiomatic-v2-adoption
title: "Gate every pre-v2 generated Haskell edition and harden idiomatic-v2 adoption"
kind: exec-plan
created_at: 2026-08-26T23:41:32Z
intention: "intention_01m1076hqbe2xr1skf75nf8hgj"
---

# Gate every pre-v2 generated Haskell edition and harden idiomatic-v2 adoption

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-dsl scaffold` writes a tree of generated Haskell modules for a consuming
application. The next release, 0.15.0.0, changes how those modules spell record fields
(the `idiomatic-v2` "edition", described below), which breaks hand-written code that
imports them. To keep that break attributable and recoverable, the tool is supposed to
refuse to regenerate an older tree until the operator passes
`--apply-generated-haskell-edition`, and then to copy every old file into a backup
directory and write a remediation report before overwriting anything. The pre-release
review [REV-14](../reviews/generated-haskell-edition-migration.md) drove the tool built
at commit `acb9ee6c` through fourteen live scenarios and found that this promise holds
only for trees whose ledger literally says `naming-edition idiomatic-v1`. A tree
produced by keiro-dsl before 0.11 has no such row, is parsed as `legacy-v1`, and is
rewritten to v2 on its next scaffold with no refusal, no backup, and no report. Three of
the six generated-API consumers named in
[the downstream audit](../audits/keiro-dsl-record-api-downstream-audit-2026-08-23.md)
are in exactly that state. The same review found that a ledger the tool cannot parse is
treated as "no ledger" and silently overwritten, that the remediation scanner misses the
forms of field access that actually break under v2, that a retry after rollback is
blocked by a stale report the rollback guide never mentions, and that the user reference
does not know the flag exists.

After this plan, an operator whose tree records any edition older than the current one —
`legacy-v1` or `idiomatic-v1` — sees the same refusal-then-apply protocol, with backups
named for the edition they came from; a legacy tree that also needs module renames is
migrated in one explicit run that requires both apply flags and lists both impacts; a
corrupt ledger refuses instead of being ignored; the report names qualified,
record-dot, record-update, and operator uses of renamed labels and says plainly that it
is attributable rather than complete; rollback followed by a fix and a retry works
without deleting anything by hand; every one of those behaviors has an Hspec example;
and the user reference, the adoption guide, the changelogs, and ADRs 15 and 19 describe
the shipped behavior. The release notes' sentence "existing scaffold ledgers require
explicit, backup-backed adoption" becomes true for every ledger keiro-dsl ever wrote.


## Progress

- [x] (2026-08-29T13:50:00Z) Milestone 1: gate every recorded pre-current edition in both scaffold paths, name the
  from-edition in refusals and backup roots, and refuse an unreadable ledger.
- [x] (2026-08-29T14:07:00Z) Milestone 2: compose sidecar, source-name, and edition migrations in one explicit run
  for legacy-v1 trees; re-run the edition preflight after sidecar renames; list source
  moves in the report.
- [x] (2026-08-29T14:18:00Z) Milestone 3: widen the Hole scanner to the forms that break under v2, print the
  attributable-only caveat in refusal and report, and regenerate the report instead of
  treating it as conflict evidence.
- [x] (2026-08-29T14:18:00Z) Milestone 4: add examples for backup conflict, interrupted apply, tamper, rollback and
  retry, and a CLI round trip through the built binary.
- [x] (2026-08-29T14:21:48Z) Milestone 5: update the user reference, the adoption guide, the downstream audit, the
  changelogs, ADR 15, and ADR 19, and validate all bundles.
- [ ] Milestone 6: make the presentation rewriter robust to Template Haskell name quotes and
  promoted ticks, with an end-state test over the tracked corpus.
- [ ] Final: run the full gate, regenerate the record inventories, record a follow-up review
  in `docs/reviews/`, and close the plan.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: The planned `LedgerRead` state constructor and `Refusal` constructor
  cannot both be named `LedgerUnreadable` because Haskell data constructors share a
  module-level namespace.
  Evidence: Both types live in `Keiro.Dsl.ScaffoldRun`; declaring the two constructors
  with the same name would produce a duplicate-constructor compile error before any
  behavior could be tested.

- Observation: A ledger-only downgrade of a freshly generated v2 fixture does not by
  itself model interrupted application bytes, because the generated files and the
  edition backups are then identical.
  Evidence: The first interrupted-apply example returned `Right` after restoring only
  the old ledger. Adding a harmless pre-adoption marker to every recorded Generated
  file before the backup made the apply overwrite every file and produced one backup
  conflict per generated path when only the ledger was restored.


## Decision Log

- Decision: Gate every recorded edition that differs from
  `Keiro.Dsl.HaskellName.currentGeneratedHaskellNamingEdition`, not only
  `IdiomaticNamingV1`, and treat "no ledger" as the only ungated case.
  Rationale: REV-14 proved the ledger row is the sole gate; a missing row parses as
  `LegacyNamingV1` in both `Keiro.Dsl.ScaffoldRecord` and `Keiro.Dsl.WorkspaceRecord`
  and today passes straight through. The three legacy consumers in the audit are real
  trees. Keying the gate on "differs from current" also means a future `idiomatic-v3`
  cannot repeat this defect.
  Date: 2026-08-26

- Decision: Migrate a legacy-v1 tree in one run that requires both
  `--apply-name-migrations` and `--apply-generated-haskell-edition`, rather than a
  two-step path.
  Rationale: The name-migration step writes the ledger at the current edition, so a
  two-step path cannot land a tree on `idiomatic-v1` first; the current guard that
  refuses an edition migration while moves are pending tells the operator to pass a flag
  that cannot satisfy it (REV-14 finding F10). One run with both flags, an edition
  backup taken before the source moves, and a report that lists the moves is the
  smallest design whose rollback is a documented file set.
  Date: 2026-08-26

- Decision: Regenerate `remediation-report.txt` on every apply and drop the report
  conflict check; the byte-identical backups remain the only conflict evidence.
  Rationale: The report is informational and changes whenever the operator edits a Hole
  between attempts, which is exactly what the guide tells them to do. Treating that as a
  conflict blocked the documented rollback-and-retry path in the live probe.
  Date: 2026-08-26

- Decision: Keep the Hole scanner lexical and over-approximating, but widen it to the
  forms that break under v2 and label it attributable in every place a count is printed.
  Rationale: The guide already carries the caveat; the refusal and report did not. A
  scanner that misses `record.failureCode` while the guide recommends record-dot for
  dual-edition code is worse than none. Full parsing is out of scope; compile errors
  after adoption stay the authority.
  Date: 2026-08-26

- Decision: Include the rewriter robustness fix (Milestone 6) even though no tracked
  module is affected today.
  Rationale: `Keiro.Dsl.GeneratedHaskellLanguage.modernizeGeneratedHaskellSource` is the
  only place a future entry in `idiomaticV2LabelMigrations` can be silently skipped, 54
  Domain modules already end in a desynchronised state, and the regression test is a
  cheap loop over the tracked corpus. Fixing it while the edition boundary is being
  frozen for release is cheaper than discovering it after.
  Date: 2026-08-26

- Decision: Name the internal three-way read state `LedgerReadUnreadable`, while keeping
  the public refusal constructor and its rendered diagnostic named `LedgerUnreadable`.
  Rationale: The refusal is the externally observed API asserted by the plan, while the
  read-state constructor is plumbing between filesystem reads and that refusal. Haskell
  cannot define both constructors with the same name in `Keiro.Dsl.ScaffoldRun`.
  Date: 2026-08-29


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

- Milestone 1 completed on 2026-08-29. Both scaffold paths now distinguish absent,
  parsed, and unreadable ledgers; refuse an unreadable current ledger before writes;
  and prepare the edition migration for every parsed edition other than the current
  edition. Backups and diagnostics name the recorded from-edition. The focused suite
  passes with 4 examples and 0 failures, and the generated record inventory check
  exits successfully.

- Milestone 2 completed on 2026-08-29. Single-file and workspace execution now inspect
  legacy-named ledgers before refusing, apply sidecar renames first when authorized,
  re-read the current ledger, and compose source moves with the edition backup when both
  flags are present. The remediation report records planned source moves. The focused
  name-migration and generated-edition groups each pass with 4 examples and 0 failures;
  the realistic legacy tests cover no flags, name-only, both flags, sidecar backups,
  source backups, the combined diagnostic, and both scaffold paths.

- Milestones 3 and 4 completed on 2026-08-29. Hole scanning now attributes prefix,
  qualified, renamed record-dot, record-field, and operator-operand forms, labels each
  use, skips comment-only lines and unchanged record-dot labels, and prints the lexical
  scanner caveat in refusals and reports. Reports are regenerated on every apply and no
  longer participate in conflict detection. The generated-edition group passes 7
  examples and the composed name-migration group passes 4, covering rollback-and-retry,
  tampered backups, interrupted apply, the real CLI boundary, and both legacy paths.

- Milestone 5 completed on 2026-08-29. The user reference, adoption guide, three
  legacy downstream-audit rows, package and root changelogs, and ADRs 15 and 19 now
  describe the implemented gate, one-run legacy composition, unreadable-ledger refusal,
  attributable scanner, regenerated report, and rollback boundary. The ADR bundle
  passes strict profile and log enforcement with separate ADR-15 and ADR-19 entries;
  both user-documentation bundles validate and graph successfully.


## Context and Orientation

The repository is a Cabal multi-package Haskell workspace (GHC 9.12, `cabal-install`
3.16, Nix flake, `just` task runner). Everything in this plan lives in the `keiro-dsl`
package under `keiro-dsl/`, its documentation under `docs/`, and its tests under
`keiro-dsl/test/`. Run every command from the repository root,
`/Users/shinzui/Keikaku/bokuno/keiro`, unless a step says otherwise.

A **scaffold** is the output of `keiro-dsl scaffold <spec> --out <dir>`: replaceable
`Generated/*.hs` modules bearing an exact `-- @generated by keiro-dsl <version>` banner,
create-once hand-owned modules called **Holes** (files such as
`Billing/Subscription/BehaviorHoles.hs` that the tool writes once and never rewrites),
a human-pasted Cabal fragment, and a machine-owned **ledger**. The ledger is a text file
of one row per fact; for a single `.keiro` file it is named
`keiro-dsl-ledger.context.<context>.txt`, for a `.keiro-workspace` it is
`keiro-dsl-ledger.workspace.<service>.txt`. The names come from
`keiro-dsl/src/Keiro/Dsl/SidecarNames.hs`. Before 0.11 the same two files were called
`keiro-dsl-scaffold-record.<context>.txt` and `keiro-dsl-manifest.<context>.txt`; those
**legacy sidecar names** are migrated by a refuse-then-apply step governed by
[ADR 22](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md)
and implemented in `keiro-dsl/src/Keiro/Dsl/SidecarMigration.hs`.

A **generated Haskell naming edition** is the presentation contract of the generated
modules: which module names, record labels, and selector functions they use. The closed
set is `Keiro.Dsl.HaskellName.GeneratedHaskellNamingEdition` with constructors
`LegacyNamingV1`, `IdiomaticNamingV1`, and `IdiomaticNamingV2`, rendered in the ledger as
the row `naming-edition legacy-v1|idiomatic-v1|idiomatic-v2`. `legacy-v1` trees have
older module names that the **name migration** (`--apply-name-migrations`) renames with
backups under `.keiro-dsl-name-migrations/legacy-v1-to-idiomatic-v1/`; that planning
lives in `keiro-dsl/src/Keiro/Dsl/HaskellSourceMove.hs` and is driven from
`planRecordedSourceMoves` in `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` and
`planWorkspaceSourceMoves` in `keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs`. A ledger
with no `naming-edition` row parses as `LegacyNamingV1` (`parseNamingEdition` in
`keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` and in
`keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs`). `idiomatic-v2`, introduced by
[plan 177](177-modernize-keiro-dsl-records-and-field-access.md), gives generated records
concise labels (`failureCode` becomes `code`) under `NoFieldSelectors` and
`OverloadedRecordDot`; the label map is `idiomaticV2LabelMigrations` in
`keiro-dsl/src/Keiro/Dsl/GeneratedHaskellLanguage.hs`, and
`modernizeGeneratedHaskellSource` in the same module applies it as a lexical rewrite of
emitted source, skipping comments and string and character literals.

The **edition migration** is the code this plan changes. Its entry point is
`preflightGeneratedHaskellEditionMigration` in `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`.
It receives the previous ledger's edition, the recorded module list, and the two sidecar
names; today its first guard returns `Right Nothing` (no migration) unless the edition is
exactly `Just IdiomaticNamingV1`. When it does prepare a migration it lists the recorded
`Generated` paths, scans the recorded Hole paths with `selectorApplication` for old
labels, computes a backup pair for every existing source under the fixed root
`generatedHaskellEditionBackupRoot`
(`.keiro-dsl-generated-haskell-migrations/idiomatic-v1-to-idiomatic-v2`), refuses if an
existing backup or the existing `remediation-report.txt` has different bytes, and returns
a `PreparedGeneratedHaskellEditionMigration`. The callers are
`executeServiceScaffoldWithRuntimePackageAndMigrations` (single file) in the same module
and `executeWorkspaceScaffoldWithMigrations` in
`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs`. Both refuse with
`GeneratedHaskellEditionRequired` when a migration is prepared and the flag is absent,
refuse with `SidecarMigrationRequired` or `NameMigrationRequired` whenever a migration is
prepared and any sidecar or source move is also pending (regardless of flags), and
otherwise call `applyPreparedGeneratedHaskellEditionMigration` (copy backups, write the
report if absent) immediately before writing modules. The ledger is written last, with
`namingEdition = currentGeneratedHaskellNamingEdition`. Refusals are the `Refusal` sum
type in `ScaffoldRun.hs`, rendered by `renderRefusals`; the CLI in
`keiro-dsl/app/Main.hs` prints them to stderr and exits 1. Both `readRecord`
(`ScaffoldRun.hs`) and `readWorkspaceRecord` (`WorkspaceScaffold.hs`) return
`Maybe`, collapsing "file absent" and "file present but unparseable" into `Nothing`.

The existing test coverage is the group `describe "generated Haskell edition migration"`
in `keiro-dsl/test/Main.hs` (search for that string): one single-file example that
downgrades a fresh ledger to `idiomatic-v1` with `scaffoldRecordWithEdition`, appends a
probe line to `BehaviorHoles.hs`, checks the refusal and an unchanged `treeSnapshot`,
applies, and checks backups, report, and rerun; and one workspace example that rewrites
the ledger row textually. Helpers you will reuse: `withTempDirectory`, `parsedSourceOf`,
`planTestServiceScaffold`, `treeSnapshot`, `scaffoldRecordWithEdition`,
`shouldComposeWorkspace`, `shouldPlanWorkspaceSpec`, and `canonicalWorkspacePath`, all
defined in `keiro-dsl/test/Main.hs`. The sidecar migration example under
`describe "sidecar migration (EP-198)"` shows how to manufacture legacy sidecar names with
`legacyContextRecordFileName` and `legacyContextManifestFileName`, and the examples that
mention `NameMigrationRequired` show how to manufacture a legacy module layout. A test
that runs the built executable already exists (search `readProcessWithExitCode
"keiro-dsl"`).

Two repository gates matter here. `scripts/check-extension-policy.sh` rejects local
record-default pragmas and `FieldSelectors` in package source.
`scripts/generate-record-migration-manifests.py --check` (run by the
`Keiro.Dsl.RecordMigration` spec inside `keiro-dsl-test`) fails whenever a record
declaration in `keiro-dsl/src` or in tracked generated output is added, removed, or
relabelled without regenerating the two checked inventories
`keiro-dsl/record-field-migration-0.15.md` and
`keiro-dsl/generated-haskell-edition-idiomatic-v2.md`; run the script without `--check`
to regenerate them after adding any record type.

Relevant local ADRs, summarized:
[ADR 15](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
requires generated presentation-edition changes to be explicit, preflighted, backed up,
and never to rewrite create-once Holes; this plan extends that rule to every recorded
pre-current edition and defines how it composes with the name migration.
[ADR 19](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
defines the editions and says moving from `idiomatic-v1` to `idiomatic-v2` is explicit
adoption, not regeneration; this plan makes the same statement for `legacy-v1`.
[ADR 22](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md)
defines the sidecar rename migration this plan sequences before the edition backup.
[ADR 38](../adr/0038-keiro-dsl-records-use-concise-labels-without-product-selectors.md)
governs the record style of any new type you add in `keiro-dsl/src` (concise labels,
record dot for reads, no selector functions). No cross-repository ADR is relevant.
The ADR bundle is OKF-profiled: allocate handles with `okf id next`, log with `okf log
add`, and validate strictly, as the Concrete Steps show.


## Plan of Work

### Milestone 1: every recorded pre-current edition is gated; an unreadable ledger refuses

At the end of this milestone, scaffolding over a tree whose ledger records `legacy-v1`
or `idiomatic-v1` refuses before writing unless `--apply-generated-haskell-edition` is
given, the refusal and the backup directory name the edition being left, and a ledger
file that exists but does not parse refuses with its path. Nothing is silently
overwritten any more, in either the single-file or the workspace path. Legacy trees that
also need renames will now refuse with `SidecarMigrationRequired` or
`NameMigrationRequired`; Milestone 2 turns that into a working path.

In `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`, change
`preflightGeneratedHaskellEditionMigration` so its first guard returns `Right Nothing`
only when the previous edition is `Nothing` (no ledger) or equals
`HaskellName.currentGeneratedHaskellNamingEdition`; every other value prepares a
migration. Replace the constant `generatedHaskellEditionBackupRoot` with a function of
the from-edition that renders
`.keiro-dsl-generated-haskell-migrations/<from>-to-<current>` using
`renderGeneratedHaskellNamingEdition` for both segments, so an `idiomatic-v1` tree keeps
its existing `idiomatic-v1-to-idiomatic-v2` directory and a legacy tree gets
`legacy-v1-to-idiomatic-v2`. Add a `fromEdition` field to
`GeneratedHaskellEditionImpact` and use it in `renderGeneratedHaskellEditionRemediation`
(`from: <edition>`) and in the `GeneratedHaskellEditionRequired` branch of
`renderRefusals`, whose first line currently hard-codes `idiomatic-v1 -> idiomatic-v2`.

Introduce a three-way ledger read. Add to `ScaffoldRun.hs`:

```haskell
data LedgerRead a
  = LedgerAbsent
  | LedgerParsed !a
  | LedgerUnreadable !FilePath
  deriving stock (Eq, Show)
```

Change `readRecord :: FilePath -> IO (LedgerRead ScaffoldRecord)` and
`readWorkspaceRecord :: FilePath -> IO (LedgerRead WorkspaceRecord)` (the latter in
`WorkspaceScaffold.hs`) to return `LedgerUnreadable path` when the file exists but
`parseRecord` or `parseWorkspaceRecord` returns `Nothing`. Add a refusal constructor
`LedgerUnreadable !FilePath` and render it as
`error: scaffold ledger <path> exists but could not be parsed; nothing was written`
followed by
`  restore it from version control or from the edition backup before scaffolding again`.
Every caller of the two readers (there are several in each execute path, including the
second read inside `executeCheckedScaffold` and the one in
`executeWorkspaceScaffoldBase`) must map `LedgerUnreadable` to that refusal before any
write, `LedgerAbsent` to the current `Nothing` behavior, and `LedgerParsed` to the
current `Just` behavior. A small helper such as `ledgerToMaybe :: LedgerRead a -> Maybe
a` keeps the downstream code unchanged once the refusal has been checked.

Tests, in the `describe "generated Haskell edition migration"` group of
`keiro-dsl/test/Main.hs`: a single-file example that downgrades the fresh ledger with
`scaffoldRecordWithEdition LegacyNamingV1`, asserts the refusal is
`[GeneratedHaskellEditionRequired impact]` with `impact.fromEdition == LegacyNamingV1`,
asserts `renderRefusals` mentions `legacy-v1 -> idiomatic-v2`, asserts `treeSnapshot`
is unchanged, applies with the flag, and asserts the backup root is
`.keiro-dsl-generated-haskell-migrations/legacy-v1-to-idiomatic-v2`; a workspace example
that deletes the `naming-edition` row textually and asserts the same refusal; and one
example per path that appends a duplicate `spec:` row (single file) or a duplicate
`service:` row (workspace; check `renderWorkspaceRecord` for the exact scalar row name)
to a fresh ledger and asserts `Left [LedgerUnreadable path]` with an unchanged tree.

### Milestone 2: one explicit run migrates a legacy-v1 tree

At the end of this milestone, a legacy tree — old sidecar names, old module names, no
edition row — is migrated by a single `scaffold` invocation carrying both
`--apply-name-migrations` and `--apply-generated-haskell-edition`. With either flag
missing the run refuses and lists everything it would do: the sidecar renames, the
source moves, and the edition impact. With both, it renames sidecars, re-reads the
ledger, takes the edition backup of every recorded file at its recorded path plus the
now current-named sidecars, performs the source moves under their own backups, writes
the modules, and writes the v2 ledger. The report lists the source moves so rollback is a
documented file set.

In `executeServiceScaffoldWithRuntimePackageAndMigrations`
(`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`), restructure the guard chain. Plan sidecar
moves first, as now. If sidecar moves are pending and `--apply-name-migrations` is
absent, refuse with `SidecarMigrationRequired` as now, but also run the edition preflight
on the ledger as it currently exists (using the legacy record name when the current one
is absent — `readRecord` on `legacyContextRecordFileName` is what the adoption path
already does) and append `GeneratedHaskellEditionRequired` to the same refusal list when
a migration would be prepared, so the operator learns about both flags in one refusal.
When the sidecar moves are applied (or none were pending), re-read the ledger and run
the edition preflight against it; the existing note `SidecarMovesAlreadyApplied` keeps
the "nothing was written" wording honest. Then plan source moves. Replace the two guards
that refuse whenever an edition migration and moves are both pending with: refuse
`[NameMigrationRequired moves, GeneratedHaskellEditionRequired impact]` when both are
pending and either flag is missing; proceed when both flags are present; keep the
existing single-flag behaviors when only one kind of migration is pending. Inside the
proceed branch keep the order `applyPreparedGeneratedHaskellEditionMigration` then
`applyPreparedSourceMoves`; the edition backup therefore captures every recorded
`Generated` file at its recorded, pre-move path. Extend
`PreparedGeneratedHaskellEditionMigration` with the planned `[SourceMove]` and have
`renderGeneratedHaskellEditionRemediation` add a `source-moves: <n>` line followed by one
`<old path> -> <new path>` line per move. Mirror every step in
`executeWorkspaceScaffoldWithMigrations` in `keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs`,
whose structure is the same. Update the two `render` branches for
`NameMigrationRequired` and `SidecarMigrationRequired` so that, when they appear beside a
`GeneratedHaskellEditionRequired` in the same list, the operator is told to pass both
flags; the simplest way is a final line appended by `renderRefusals` when both kinds are
present: `this tree needs both --apply-name-migrations and
--apply-generated-haskell-edition in one run`.

Tests: build a legacy tree in a temporary directory by scaffolding fresh, renaming the
two sidecars to `legacyContextRecordFileName` and `legacyContextManifestFileName`,
deleting the `naming-edition` row, and (reusing the fixture construction from the
existing `NameMigrationRequired` examples) renaming one generated module to its legacy
module name and rewriting the ledger row for it. Assert: no flags refuses with both
`SidecarMigrationRequired` and `GeneratedHaskellEditionRequired` and an unchanged tree;
`--apply-name-migrations` alone refuses with `NameMigrationRequired` and
`GeneratedHaskellEditionRequired` after the sidecar rename (assert the
`SidecarMovesAlreadyApplied` note is present and only the two sidecars changed);
`--apply-generated-haskell-edition` alone refuses likewise; both flags succeed, the
backup root `legacy-v1-to-idiomatic-v2` holds every recorded generated file at its
pre-move path and both current-named sidecars, `.keiro-dsl-name-migrations/` holds the
moved module, the report lists the move, the ledger says `idiomatic-v2`, the Hole bytes
are unchanged, and a rerun with both flags is byte-idempotent. Add the workspace twin
using the `canonicalWorkspacePath` fixture.

### Milestone 3: an honest, wider Hole scanner and a report that never blocks

At the end of this milestone the refusal and the report enumerate qualified
applications, record-dot reads of renamed labels, record construction and update
fields, and operator operands of old labels in Hole files, each tagged with its form;
both print the sentence that the list is attributable and not complete; and the report is
rewritten on every apply so a rollback, a Hole edit, and a retry succeed.

In `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` replace `selectorApplication` with a
function that returns every use site on a line with its form. Define:

```haskell
data HoleUseForm
  = PrefixApplication
  | QualifiedApplication
  | RecordDotRenamed
  | RecordFieldBinding
  | OperatorOperand
  deriving stock (Eq, Ord, Show)
```

and add `form :: !HoleUseForm` to `GeneratedHaskellEditionUse`. The detection stays
lexical, on one line at a time, with the same identifier-boundary test as today: a label
preceded by `<Upper>.` with an application to its right is `QualifiedApplication`; a
label preceded by `.` and a lower-case identifier character before that dot is
`RecordDotRenamed` only when the label's target in `idiomaticV2LabelMigrations` differs
from the label (an unchanged concise label is fine under record dot); a label followed by
optional spaces and `=` inside a brace context (any `{` earlier on the line without a
matching `}`) is `RecordFieldBinding`; a label followed by optional spaces and one of
`<$>`, `<&>`, `$`, `.`, `&`, or `` ` `` is `OperatorOperand`; the current rule remains
`PrefixApplication`. Skip a line whose first non-blank characters are `--`. Render each
use as `<path>:<line>: <label> (<form>) -> <replacement>` where the replacement for a
renamed label is `record.<target>`, for a `RecordFieldBinding` is `<target> = ...`, and
for an unchanged label under record dot is "no change needed". Append to both the
`GeneratedHaskellEditionRequired` rendering and the report the line
`attributable uses only: unchanged concise labels and files outside the recorded Hole
paths are not scanned; compile errors after adoption are the authority`.

Remove `checkReport` from the preflight and make
`applyPreparedGeneratedHaskellEditionMigration` write the report unconditionally.

Tests: extend the single-file example so the probe appended to `BehaviorHoles.hs`
contains, on separate lines, `failureCode f`, `BC.failureCode f`, `f.failureCode`,
`f {failureCode = "x"}`, `failureCode <$> fs`, a `-- failureCode f` comment, and
`f.code`; assert exactly five uses with the expected forms and none for the comment or
the unchanged label. Add an example that applies, restores the backed-up set to the
output root, removes the probe from the Hole, applies again, and asserts success with
a report whose `hand-owned-selector-uses:` line reads `0`.

### Milestone 4: conflict, interruption, tamper, and CLI coverage

At the end of this milestone every refusal branch the live probe exercised has an
example, and one example drives the real executable through refusal, apply, and rerun.

In the same test group add: a tampered-backup example (apply once, restore the ledger to
`idiomatic-v1` and every backed-up file to its backup bytes, then change one byte of one
backup file, and assert `Left [GeneratedHaskellEditionRefusal reasons]` with one reason
naming that file and an unchanged tree); an interrupted-apply example (after a successful
apply, restore the ledger to `idiomatic-v1` while leaving the v2 modules in place, and
assert a refusal with one `edition backup conflict` reason per generated file, then
restore all backed-up files and assert the rerun succeeds with a `treeSnapshot` equal to
the clean apply); and a CLI example following the existing `readProcessWithExitCode
"keiro-dsl"` pattern that scaffolds a fixture into a temporary directory, downgrades the
ledger row with a text replacement, asserts exit code 1 and the refusal text on stderr
with an unchanged tree, then asserts exit 0 with the flag and exit 0 again on rerun.
Add a short comment above the interrupted-apply example stating the documented
condition: conflict detection runs only while the ledger records a pre-current edition.

### Milestone 5: documentation, changelogs, and ADRs describe the shipped behavior

At the end of this milestone a reader of the user reference learns about the flag and
the refusal where they learn about `--apply-name-migrations`, the adoption guide covers
legacy trees and states the conditions the code actually enforces, the changelogs say
what changes for consumers, the downstream audit points its three legacy consumers at
the one-run path, and ADRs 15 and 19 record the durable rule.

Edit `docs/user/typed-spec-toolchain.md`: in the scaffold section that begins "The one
source-moving exception is an upgrade from a recorded legacy generated-name edition",
change "one" to "two" and add a paragraph after it describing the edition migration in
the same register — ordinary scaffolding refuses without mutation and prints every
recorded Generated path, both sidecars, and attributable Hole uses; rerun with
`--apply-generated-haskell-edition`; backups under
`.keiro-dsl-generated-haskell-migrations/<from>-to-idiomatic-v2/`; a legacy tree needs
both flags in one run; conflict detection applies while the ledger records the older
edition. In the paragraph describing the Cabal fragment, list the four defaults
`DuplicateRecordFields`, `NoFieldSelectors`, `OverloadedRecordDot`, and
`OverloadedStrings`. Edit `docs/guides/adopting-keiro-dsl-idiomatic-v2.md`: add a
section for legacy-v1 trees; state in the roll-back section that the backup set is the
ledger-recorded files and the two sidecars (a conformance package's own files are
written after the ledger and are not backed up), that `remediation-report.txt` is
regenerated and may be left in place, and that after a legacy migration the source-move
destinations listed in the report must also be removed to return to the legacy layout;
and state under "If an apply was interrupted" that the check runs only while the ledger
records the older edition. Update the three legacy rows of
`docs/audits/keiro-dsl-record-api-downstream-audit-2026-08-23.md` to name the one-run
path. In `keiro-dsl/CHANGELOG.md` under `## Unreleased`, reword the second breaking
entry so "Existing ledgers" covers every recorded pre-v2 edition including trees with no
edition row, and add entries for the unreadable-ledger refusal, the widened scanner with
its caveat, and the regenerated report; mirror the consumer-visible sentence in the root
`CHANGELOG.md`. Update ADR 15's decision text on backup-backed adoption and ADR 19's
statement about explicit adoption to cover `legacy-v1` and the one-run composition,
advance each `timestamp`, and add one `okf log add` entry per ADR. Both user
documentation bundles are OKF-validated, so keep frontmatter intact.

### Milestone 6: the presentation rewriter cannot desynchronise on generated syntax

At the end of this milestone `modernizeGeneratedHaskellSource` finishes every tracked
Generated module in its `Code` state, a unit test proves that identifiers after a
Template Haskell name quote or a promoted tick are still rewritten, and corpus
regeneration shows zero byte changes.

In `keiro-dsl/src/Keiro/Dsl/GeneratedHaskellLanguage.hs`, change the `Code` rule for
`'` so it enters `CharacterLiteral` only when what follows is a character literal: the
next character is `\` (an escape, consumed to the closing `'`), or the character after
next is `'` (a one-character literal). Otherwise — `'name`, `''Type`, `'[]`, `'(` — emit
the tick and stay in `Code`. Change the `--` rule so a run of two or more dashes starts
a line comment only when the character after the run is not a Haskell symbol character
(`!#$%&*+./<=>?@\^|-~:`), which is the language's own rule and keeps `-->` an operator.
Export `modernizeGeneratedHaskellSourceWithState :: Text -> (Text, RewriteState)` (or
make `RewriteState` and a final-state accessor available to the test suite) so a test can
observe the end state. Add to `keiro-dsl/test/Main.hs` an example that walks every
tracked file under `keiro-dsl/test` whose path contains `/Generated/` (use
`git ls-files` through `readProcessWithExitCode`, as other examples do) and asserts the
end state is `Code` for each; before the fix this example fails for the 54 Domain
modules, which is the demonstration. Add a unit example with the source
`x = ''Foo\ny = sourceFile r\n` asserting the second line becomes `y = file r`.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro`. The package builds with
`cabal build keiro-dsl`; the focused suite runs with the `--match` filter shown; the
whole gate is `just verify` and needs the local PostgreSQL that `just verify` itself
provisions.

Before Milestone 1, reproduce the defect so you can watch it disappear. The sandbox
uses a scratch copy of the 0.14.0.0 conformance corpus, so nothing in the repository is
touched. `sed` here is GNU sed (the Nix toolchain), so `-i` takes no suffix argument.

```bash
S=/private/tmp/edition-probe && rm -rf "$S" && mkdir -p "$S"
git archive keiro-0.14.0.0 keiro-dsl/test | tar -x -C "$S"
KEIRO_DSL=$(cabal list-bin keiro-dsl)
cd "$S"
sed -i '/^naming-edition /d' keiro-dsl/test/conformance-coldstart/keiro-dsl-ledger.context.billing.txt
"$KEIRO_DSL" scaffold keiro-dsl/test/fixtures/subscription.keiro --out keiro-dsl/test/conformance-coldstart; echo "exit=$?"
grep '^naming-edition' keiro-dsl/test/conformance-coldstart/keiro-dsl-ledger.context.billing.txt
ls keiro-dsl/test/conformance-coldstart/.keiro-dsl-generated-haskell-migrations 2>&1
```

Before the fix the transcript ends with:

```text
scaffold: keiro-dsl/test/fixtures/subscription.keiro -> keiro-dsl/test/conformance-coldstart
exit=0
naming-edition idiomatic-v2
ls: cannot access '...': No such file or directory
```

After Milestone 1 the same commands end with:

```text
error: generated Haskell edition migration required: legacy-v1 -> idiomatic-v2; nothing was written
re-run scaffold with --apply-generated-haskell-edition after reviewing this impact:
  generated files: 10
  ...
exit=1
```

and the ledger still has no row. For the realistic legacy shape, additionally rename the
sidecars before running:

```bash
cd "$S/keiro-dsl/test/conformance-coldstart"
mv keiro-dsl-ledger.context.billing.txt keiro-dsl-scaffold-record.billing.txt
mv keiro-dsl-cabal-fragment.context.billing.txt keiro-dsl-manifest.billing.txt
cd "$S"
"$KEIRO_DSL" scaffold keiro-dsl/test/fixtures/subscription.keiro --out keiro-dsl/test/conformance-coldstart --apply-name-migrations; echo "exit=$?"
```

Before Milestone 2 this exits 0 with `sidecar migration: applied (2 move(s))` and a v2
ledger. After Milestone 2 it exits 1, prints the edition impact beneath the applied
sidecar note, and the final line reads `this tree needs both --apply-name-migrations and
--apply-generated-haskell-edition in one run`; rerunning with both flags exits 0 and
creates `.keiro-dsl-generated-haskell-migrations/legacy-v1-to-idiomatic-v2/` beside the
v2 ledger.

For each milestone, the edit-build-test loop is:

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test --test-options='--match "generated Haskell edition migration"'
```

Expect `Test suite keiro-dsl-test: PASS` and a line such as `9 examples, 0 failures`
(the count grows with each milestone). Whenever you add or change a record declaration
in `keiro-dsl/src` (the `LedgerRead`, `HoleUseForm`, and extended impact types will do
this), regenerate the inventories and confirm the drift gate:

```bash
python3 scripts/generate-record-migration-manifests.py
python3 scripts/generate-record-migration-manifests.py --check; echo "check=$?"
git diff --stat keiro-dsl/record-field-migration-0.15.md keiro-dsl/generated-haskell-edition-idiomatic-v2.md
```

`check=0` is required; the diff must show only rows for the types you added.

After Milestone 6, prove the rewriter change is byte-neutral for the current corpus:

```bash
just corpus-regen
git status --short keiro-dsl/test | head
```

The second command must print nothing.

For Milestone 5, validate every bundle you touched and log the ADR updates:

```bash
okf log add docs/adr --kind Update -m "Gate every recorded pre-current generated edition, compose it with name migration in one explicit run, and regenerate the remediation report (plan 268)."
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just user-documentation-validate
```

Each `okf validate` prints `OK: <n> concepts`. Then format and run the complete gate in
the background, checking the exit status inside the log rather than the tail:

```bash
nix fmt
(just verify; echo "EXIT=$?") > /private/tmp/plan-268-verify.log 2>&1 &
```

and later `grep -E '^EXIT=|FAIL' /private/tmp/plan-268-verify.log` must show `EXIT=0`
and no `FAIL`.

Commit after each milestone with the trailers:

```text
feat(dsl): gate every pre-current generated edition

ExecPlan: docs/plans/268-gate-every-pre-v2-generated-haskell-edition-and-harden-idiomatic-v2-adoption.md
Intention: intention_01m1076hqbe2xr1skf75nf8hgj
```

When the plan is complete, add a follow-up record `REV-16` to `docs/reviews/` (the
bundle is OKF-profiled; copy the frontmatter shape of
`docs/reviews/generated-haskell-edition-migration.md`, set `outcome: approved`, name
the commit reviewed, add index and log lines) and run `just reviews-validate`.


## Validation and Acceptance

The change is accepted when all of the following are observable. Scaffolding the
scratch copy above with its edition row deleted exits 1, writes nothing (compare
`find . -type f -exec sha256sum {} + | sort | sha256sum` before and after), and names
`legacy-v1 -> idiomatic-v2`; the same tree with legacy sidecar names and only
`--apply-name-migrations` exits 1 after the sidecar rename with the combined message,
and with both flags exits 0 leaving a `legacy-v1-to-idiomatic-v2` backup directory whose
files are byte-identical to the pre-run files, a report that lists any source moves,
and a ledger row `naming-edition idiomatic-v2`; rerunning that command exits 0 and
changes no bytes. Appending a duplicate `spec:` row to a ledger and scaffolding exits 1
with `scaffold ledger ... could not be parsed` and an unchanged tree. A Hole containing
the five probe forms produces a refusal listing five uses with their forms and the
attributable-only sentence; a comment and an unchanged label produce none. After an
apply, restoring the backed-up set, editing the Hole, and applying again exits 0 with an
updated report. `cabal test keiro-dsl-test --test-options='--match "generated Haskell
edition migration"'` passes with at least eleven examples covering: legacy refusal
(single and workspace), unreadable ledger (single and workspace), both-flags legacy
migration (single and workspace), scanner forms, rollback-and-retry, tampered backup,
interrupted apply, and the CLI round trip. The rewriter end-state example passes over
every tracked Generated module and `just corpus-regen` changes no tracked file. `just
verify` exits 0. `okf validate` passes strictly for `docs/adr`, `docs/user`,
`docs/guides`, and `docs/reviews`, and `scripts/check-extension-policy.sh` and
`scripts/generate-record-migration-manifests.py --check` exit 0.


## Idempotence and Recovery

Every migration in this plan remains refuse-then-apply: a run without the required
flags writes nothing except, when sidecar renames are applied, the renames themselves,
which are idempotent and reported. Backups are never overwritten — a backup with
different bytes is a refusal — so rerunning an apply cannot lose the pre-migration tree.
Rollback of an `idiomatic-v1` migration is restoring every file under the backup root to
the output root; rollback of a legacy migration additionally removes the source-move
destinations listed in the report and restores the moved files from
`.keiro-dsl-name-migrations/`. The report is regenerated and needs no restoration. The
scratch reproduction is disposable; recreate it from `git archive` whenever a step has
altered it. Code changes are additive until a milestone's tests pass; if a milestone is
abandoned mid-way, `git stash` or `git checkout -- keiro-dsl` returns the tree to the
last commit, and the record inventories are regenerated by the script rather than edited
by hand. If `just corpus-regen` after Milestone 6 changes any tracked file, the rewriter
change altered real output: revert it and record the offending module in Surprises &
Discoveries before proceeding.


## Interfaces and Dependencies

No new package dependency is needed; everything uses `base`, `text`, `containers`,
`directory`, `filepath`, and `process`, which `keiro-dsl` and its test suite already
depend on. New records follow ADR 38: concise labels, strict fields, `deriving stock`,
reads through record dot.

At the end of Milestone 1, `Keiro.Dsl.ScaffoldRun` exports:

```haskell
data LedgerRead a = LedgerAbsent | LedgerParsed !a | LedgerUnreadable !FilePath
readRecord :: FilePath -> IO (LedgerRead ScaffoldRecord)
generatedHaskellEditionBackupRoot :: GeneratedHaskellNamingEdition -> FilePath
data GeneratedHaskellEditionImpact = GeneratedHaskellEditionImpact
  { fromEdition :: !GeneratedHaskellNamingEdition,
    generatedPaths :: ![FilePath],
    sidecarPaths :: ![FilePath],
    handOwnedUses :: ![GeneratedHaskellEditionUse]
  }
-- Refusal gains: LedgerUnreadable !FilePath
```

and `Keiro.Dsl.WorkspaceScaffold` exports `readWorkspaceRecord :: FilePath -> IO
(LedgerRead WorkspaceRecord)`. `preflightGeneratedHaskellEditionMigration` keeps its
signature; its `Maybe GeneratedHaskellNamingEdition` argument is `Nothing` only when no
ledger exists.

At the end of Milestone 2, `PreparedGeneratedHaskellEditionMigration` carries
`sourceMoves :: ![SourceMove]`, and both execute functions accept the same two `Bool`
flags they accept today with the composed semantics described in Milestone 2.

At the end of Milestone 3, `Keiro.Dsl.ScaffoldRun` exports `HoleUseForm (..)` and
`GeneratedHaskellEditionUse` carries `form :: !HoleUseForm`; `checkReport` no longer
exists.

At the end of Milestone 6, `Keiro.Dsl.GeneratedHaskellLanguage` exports
`modernizeGeneratedHaskellSourceWithState :: Text -> (Text, RewriteState)` and
`RewriteState (..)`, with `modernizeGeneratedHaskellSource` unchanged in type and, for
every tracked module, in output.
