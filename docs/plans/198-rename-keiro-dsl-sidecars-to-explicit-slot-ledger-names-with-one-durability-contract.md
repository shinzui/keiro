---
id: 198
slug: rename-keiro-dsl-sidecars-to-explicit-slot-ledger-names-with-one-durability-contract
title: "Rename keiro-dsl sidecars to explicit-slot ledger names with one durability contract"
kind: exec-plan
created_at: 2026-08-05T12:50:41Z
intention: "intention_01kz84b5jre3187dmmyjmd02fc"
master_plan: "docs/masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md"
---

# Rename keiro-dsl sidecars to explicit-slot ledger names with one durability contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan implements the revised
[IR-19](../improvement-requests/give-keiro-dsl-generated-sidecars-honest-names-and-one-durability-contract.md)
inside [MasterPlan 29](../masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md)'s breaking
release window.


## Purpose / Big Picture

A `keiro-dsl scaffold` run writes small text files next to the generated Haskell — this plan
calls them "sidecars". Today their names lie about their roles. The files named
`keiro-dsl-scaffold-record.*.txt` and `keiro-dsl-conformance-record.txt` are machine-read
ledgers: the tool parses them on every later run to detect stale files, mapping drift, and
ownership moves, and losing one silently destroys that history. The file named
`keiro-dsl-manifest.*.txt` is never parsed by anything — it is a Cabal fragment a human pastes
into their `.cabal` stanza. Meanwhile the hand-authored workspace input
(`service.keiro-workspace`) is *also* called a "manifest" in prose. One word, three meanings,
and the machine-owned files are the ones whose names suggest disposability.

After this plan, every sidecar name states its role and audience: the machine-read ledgers are
named `keiro-dsl-ledger.*` (with an explicit `workspace`/`context` slot segment so the two
namespaces cannot collide by construction), the pasted fragment is named
`keiro-dsl-cabal-fragment.*`, and "manifest" refers only to the authored workspace input. A
scaffold run over a directory that still carries old-name ledgers refuses with the exact rename
plan and performs it only under the existing `--apply-name-migrations` flag, so established
output trees can never be silently treated as fresh. Finally, the conformance package's ledger
is rebuilt on the workspace ledger's forward-compatibility conventions (typed rows, JSON
payloads, unknown rows and keys ignored) so an older binary can no longer be broken by a newer
row, closing the durability gap IR-19 documents.

To see it working: scaffold any fixture spec into a fresh directory and observe the new sidecar
names; re-scaffold a tree prepared with the old names and observe a refusal naming the renames;
re-run with `--apply-name-migrations` and observe identical stale/drift reporting to a
pre-rename run, with the ledgers now under their new names and no orphaned old-name files.


## Progress

- [x] (2026-08-05T21:03:29Z) M1: Added the `Keiro.Dsl.SidecarNames` authority and wired
      the new context/workspace ledger and cabal-fragment names through standalone,
      workspace, and adoption code; `cabal build keiro-dsl` passes.
- [x] (2026-08-05T21:03:29Z) M1: Added `SidecarMigrationRequired`, duplicate retirement,
      recoverable sidecar backups, applied-move reporting, and pre-read planning in both
      scaffold entry points.
- [x] (2026-08-05T21:32:35Z) M1: Added and passed refusal, apply, idempotence,
      duplicate-retirement, stale-history, dual-name adoption, workspace, and explicit-slot
      non-collision regressions.
- [x] (2026-08-05T21:03:29Z) M2: Renamed the conformance ledger and rebuilt its renderer
      and parser on header-plus-typed-JSON rows with unknown-extension tolerance; legacy
      conversion is part of the sidecar migration planner and the library builds.
- [x] (2026-08-05T21:32:35Z) M2: Added and passed unknown-row/key, service mismatch,
      unsafe/awkward-path, duplicate-path, and lossless legacy-conversion regressions.
- [x] (2026-08-05T21:32:35Z) M3: Renamed the 69 committed corpus sidecars, replayed all
      41 scaffold invocations byte-clean, published the user-guide glossary and breaking
      CHANGELOG entry, accepted ADR 0022, amended ADR 0015, and closed IR-19.


## Surprises & Discoveries

- Observation: The already-planned `ConformancePackagePlan` carries the relative package
  directory before filesystem preflight, so the sidecar migration layer can locate and
  convert a legacy conformance record before `preflightConformancePackage` reads history,
  without moving record-format ownership out of `Keiro.Dsl.ConformancePackage`.
  Evidence: `cabal build keiro-dsl` compiled the resulting acyclic dependency order
  `SidecarNames -> ConformancePackage -> SidecarMigration -> ScaffoldRun`.
  Date: 2026-08-05.
- Observation: The tracked corpus held 69 sidecars under historical names: one
  conformance ledger and 34 ledger/Cabal-fragment pairs. Regeneration changed only the
  conformance ledger's intentional format bytes; every standalone and workspace ledger
  and fragment was a pure Git rename.
  Evidence: the implementation commit records 68 100%-similarity renames plus the
  conformance record delete/add, and `keiro-dsl-corpus-regen check` reports 41 of 41
  invocations, record/disk consistency, Cabal inventory consistency, and corpus status OK.
  Date: 2026-08-05.
- Observation: A conformance fixture's source filename (`hospital-surge.keiro`) is not its
  service identity; the declared checked context is `hospital-capacity`.
  Evidence: the first full DSL run exposed an assertion that used the filename stem, while
  the actual converted ledger correctly retained `contextName ctx`. The regression now
  derives both its expected key and mismatch mutation from the checked context.
  Date: 2026-08-05.


## Decision Log

- Decision: Use `ledger`, not `lock`, as the machine-owned sidecar stem, rejecting IR-19's
  original `keiro-dsl-lock.*` proposal.
  Rationale: every ecosystem lockfile (`Cargo.lock`, `flake.lock`, `package-lock.json`) is
  safely regenerable — delete it and the tool rebuilds it. These files are the opposite:
  deleting one silently destroys scaffold history and re-arms the adoption branch. `lock`
  would invite the exact reflex ("delete and regenerate") the file cannot survive. `ledger`
  carries the intended conventions — committed, machine-owned, append-tolerant, never
  discard — with no regenerability connotation, and it is the word IR-19's own prose used
  for these files throughout.
  Date: 2026-08-05.
- Decision: Make the name slot explicit — `keiro-dsl-ledger.workspace.<service>.txt` and
  `keiro-dsl-ledger.context.<context>.txt` — instead of distinguishing the slots by segment
  count.
  Rationale: IR-19's original shape (`keiro-dsl-lock.<context>.txt` beside
  `keiro-dsl-lock.workspace.<service>.txt`) collides in spirit for a context literally named
  `workspace` and needed a written proof-by-segment-count in a header comment. Distinct
  literal second segments make collision-freedom structural; no prose proof is required.
  The cabal fragments follow the same rule for uniformity.
  Date: 2026-08-05.
- Decision: Keep the conformance ledger's qualifier (`keiro-dsl-conformance-ledger.txt`)
  rather than IR-19's original bare `keiro-dsl-lock.txt`.
  Rationale: a name whose meaning depends on which directory you found it in is fragile, and
  a bare name makes the workspace/conformance families indistinguishable to grep. The
  qualified name is still unique inside `keiro-dsl-conformance.<slot>/`.
  Date: 2026-08-05.
- Decision: Migrate old-name trees with the existing refuse-then-apply rail
  (`--apply-name-migrations`) performing a file move, not with IR-19's original silent
  fallback-read plus a permanent `superseded-by:` marker on the old file.
  Rationale: the refusal guarantees the critical invariant (an old-name tree can never
  present as fresh) even more strongly than fallback, matches the tool's established
  refusal-over-silent-action behavior from the generated-name migration shipped in this same
  release window, leaves no permanent zombie files, avoids the ambiguous
  both-names-exist-and-disagree state fallback never addressed, and does not overload the
  `superseded-by:` marker, which today means exactly one thing: a context record adopted
  into a workspace. The never-delete rule protects consumer-owned code a human may have
  edited; the tool's own machine-owned ledger, moved byte-identically, loses nothing.
  Date: 2026-08-05.
- Decision: Rename and rebuild the conformance ledger in one plan and one breaking window,
  but as its own milestone (M2) after the name/migration milestone (M1).
  Rationale: the rename already makes the file invisible to older binaries, so one
  compatibility break covers both changes; sequencing the format rebuild after the naming
  rail exists avoids converting the file twice.
  Date: 2026-08-05.
- Decision: Refuse when the required sidecar retirement path already exists; never replace
  a previous backup, even if an active old/current-name duplicate is otherwise migratable.
  Rationale: the backup slot is the recovery evidence for an earlier reviewed migration.
  Overwriting it would make the apply flag destructive and would violate the plan's
  byte-preservation guarantee. A conflict names the path and leaves the tree unchanged.
  Date: 2026-08-05.
- Decision: Preserve the existing standalone and workspace ledger bytes and internal v1
  headers while changing their external filenames; only the conformance ledger receives a
  format conversion.
  Rationale: the standalone/workspace row formats already have the required extension
  tolerance. Keeping their bytes unchanged makes stale, drift, mapping, adoption, and
  ownership evidence provably continuous across a pure name migration.
  Date: 2026-08-05.


## Outcomes & Retrospective

Plan 198 is complete. Fresh standalone and workspace scaffolds now write structurally
disjoint `ledger.context` / `ledger.workspace` histories and equivalently slotted Cabal
fragments; enabled service packages write `keiro-dsl-conformance-ledger.txt`. One exposed
name authority supplies every current and historical spelling.

Established trees cannot silently lose history. Both scaffold entry points plan sidecar
moves before reading a ledger, refuse without mutation, and apply reviewed renames through
`--apply-name-migrations`. Duplicate historical files are retained under the sidecar-v1
backup slot, existing backups are conflicts, applied moves are reported, and a repeated run
is a no-op. Workspace adoption deliberately retains current-first/legacy-second lookup and
marks the actual evidence file.

The conformance ledger now uses a versioned header and typed JSON file rows. Unknown row
kinds and JSON keys are extension-safe, awkward safe paths round-trip, and corruption,
unsafe paths, case-folded duplicates, and service-key mismatches remain refusals. Legacy
records convert only on explicit apply and retain their original bytes as recovery evidence.

Validation passed: `cabal test all` (including 598 DSL examples and every generated
conformance component), the focused conformance suites, the 41-invocation corpus check with
record/disk and Cabal inventory consistency, strict validation of 22 ADRs and 19 improvement
requests, formatter/pre-commit policy, and Git whitespace checks. ADR 0022 captures the new
durable contract, ADR 0015 uses the current names, IR-19 is implemented, and the user guide
and Unreleased breaking notes state the upgrade behavior.


## Context and Orientation

`keiro-dsl` (the Haskell package under `keiro-dsl/` in this repository) compiles a typed
`.keiro` service specification into generated Haskell plus explicit typed holes. The
`scaffold` CLI command writes that output into a consumer-chosen directory, together with the
sidecar text files this plan renames. Two scaffold shapes exist: a *standalone context*
scaffold (one `.keiro` file, driven by `Keiro.Dsl.ScaffoldRun`) and a *workspace* scaffold (a
hand-authored `service.keiro-workspace` input composing several member `.keiro` files, driven
by `Keiro.Dsl.WorkspaceScaffold`). A workspace scaffold may additionally emit a runnable
*conformance package* (`Keiro.Dsl.ConformancePackage`) into a
`keiro-dsl-conformance.<slot>/` directory.

The sidecars today, by full current name and role:

- `keiro-dsl-scaffold-record.<context>.txt` — the standalone ledger. Written by
  `Keiro.Dsl.ScaffoldRun` (the write is at `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs:573`,
  the read is `readRecord` at `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs:817`). The name
  helper is `recordFileName` at `keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs:226`.
- `keiro-dsl-scaffold-record.workspace.<service>.txt` — the workspace ledger. Name helper
  `workspaceRecordFileName` at `keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs:361`; read by
  `readWorkspaceRecord`, resolved at `keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs:416`.
  The module header comment at `keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs:1-45` documents
  the format and the coexistence argument this plan restates.
- `keiro-dsl-conformance-record.txt` — the conformance package's ledger, name constant
  `conformanceRecordFileName` at `keiro-dsl/src/Keiro/Dsl/ConformancePackage.hs:129`, read
  by `readPreviousRecord` (`keiro-dsl/src/Keiro/Dsl/ConformancePackage.hs:372`), parsed by
  `parseConformancePackageRecord` (`:325`), rendered by `renderConformancePackageRecord`
  (`:312`).
- `keiro-dsl-manifest.<context>.txt` and `keiro-dsl-manifest.workspace.<service>.txt` — the
  never-parsed Cabal fragment a human pastes into the consuming stanza. Rendered by
  `Keiro.Dsl.Manifest.renderManifestForServiceWithFacade`
  (`keiro-dsl/src/Keiro/Dsl/Manifest.hs:67`); the standalone write hardcodes the name inline
  at `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs:571`, the workspace name helper is
  `workspaceManifestFileName` at `keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs:365`.
- `keiro-dsl-migration-report.workspace.<service>.txt` — the one-shot legacy-adoption report
  (`workspaceMigrationReportFileName`, `keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs:370`).
  Its name is accurate and does not change.

Two durability contracts currently diverge. The workspace ledger
(`Keiro.Dsl.WorkspaceRecord`) is line-oriented with a versioned header line
(`keiro-dsl workspace scaffold record v1`), scalar `key value` rows, and typed rows carrying
canonical single-line JSON payloads (`module {...}`, `mapping {...}`, `binding {...}`,
`adopted {...}`); unknown row kinds and unknown JSON keys are ignored, and absolute or
`..`-bearing paths are rejected before being joined to an output root. The conformance ledger
has none of that: `parseConformancePackageRecord` whitespace-splits rows with `T.words`,
requires `schema == 1` exactly, and invalidates the whole record unless
`knownRows == length rows` (`keiro-dsl/src/Keiro/Dsl/ConformancePackage.hs:332-333`), so any
row added by a future version makes older binaries hard-refuse the entire scaffold run
(`:363-365` via `InvalidConformancePackageRecord`). A path containing a space is unparsable
(`parseFile` matches exactly three tokens, `:349-351`).

The rename hazard: `readWorkspaceRecord` resolves one exact path. If the name changes with no
migration step, an established tree presents as fresh — `previous` is `Nothing`, stale/drift/
ownership-move reporting all go silent, and the one-shot adoption branch at
`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs:444-446` can fire against a tree that was never
legacy. The migration must therefore be part of this change, and it must be loud.

The refuse-then-apply rail this plan extends already shipped in this release window: ordinary
scaffolding reports planned generated-Haskell source moves and writes nothing
(`NameMigrationRequired`, surfaced with the remediation line at
`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs:930`:
"re-run scaffold with --apply-name-migrations after reviewing these source moves:"), while
`scaffold --apply-name-migrations` (CLI switch at `keiro-dsl/app/Main.hs:125-126`) applies
them with recoverable backups under
`.keiro-dsl-name-migrations/legacy-v1-to-idiomatic-v1/<previous-path>`
(`keiro-dsl/src/Keiro/Dsl/HaskellSourceMove.hs:89`). Entry points:
`executeWorkspaceScaffoldWithNameMigrations`
(`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs:402`) and
`executeServiceScaffoldWithRuntimePackageAndNameMigrations`
(`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs:515`).

Adoption (`Keiro.Dsl.WorkspaceAdoption`) is the one deliberate legacy-reading path: when a
workspace has no ledger, it imports pre-workspace history by reading a context-keyed record
(`recordFileName` at `keiro-dsl/src/Keiro/Dsl/WorkspaceAdoption.hs:151`) and appending a
`superseded-by:` line via `markLegacyRecordSuperseded` (`:170-185`). After this plan, that
marker keeps its single meaning (context history adopted into a workspace); sidecar
migration never writes it.

Relevant ADRs, scanned per the skill's ADR workflow:
[ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
establishes that workspace history is workspace-keyed with attributable adoption — this plan
preserves that contract and only changes the file's name and the collision argument.
[ADR 0020](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md)
establishes the conformance package shape whose ledger M2 rebuilds.
[ADR 0019](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
is context for why the refuse-then-apply migration rail exists. No ADR currently records the
sidecar naming contract; M3 adds one.

Churn inventory verified against the working tree: 14 sidecar-name literals across
`keiro-dsl/src` and `keiro-dsl/app` (three are the defining helpers), 14 mentions in
`keiro-dsl/test/Main.hs`, 3 in `docs/user/typed-spec-toolchain.md` (lines 1304, 1346, 1395),
and committed fixture sidecars such as
`keiro-dsl/test/conformance-service-package/runtime/src/keiro-dsl-conformance.workspace.workspace-proof/keiro-dsl-conformance-record.txt`
and the record/manifest pair under `keiro-dsl/test/conformance-aggregate-scalars/`.


## Plan of Work

The final naming rule, applied everywhere: `ledger` names a machine-owned machine-read file;
`manifest` names only the artifact a human authors (`service.keiro-workspace`); every other
sidecar name states what a human does with it. All sidecars keep `.txt` — the ledgers are
line-oriented, not JSON documents, and audience belongs in the stem.

| Current name | New name |
| --- | --- |
| `keiro-dsl-scaffold-record.<context>.txt` | `keiro-dsl-ledger.context.<context>.txt` |
| `keiro-dsl-scaffold-record.workspace.<service>.txt` | `keiro-dsl-ledger.workspace.<service>.txt` |
| `keiro-dsl-conformance-record.txt` | `keiro-dsl-conformance-ledger.txt` |
| `keiro-dsl-manifest.<context>.txt` | `keiro-dsl-cabal-fragment.context.<context>.txt` |
| `keiro-dsl-manifest.workspace.<service>.txt` | `keiro-dsl-cabal-fragment.workspace.<service>.txt` |
| `keiro-dsl-migration-report.workspace.<service>.txt` | unchanged |

Because the second segment is a literal (`context` or `workspace`), the two ledger slots and
the two fragment slots are collision-free by construction, including for a context literally
named `workspace` (`keiro-dsl-ledger.context.workspace.txt` versus
`keiro-dsl-ledger.workspace.<service>.txt`). No segment-count argument is needed; the
`Keiro.Dsl.WorkspaceRecord` header comment must be rewritten to say exactly this while keeping
the legacy-coexistence explanation for adoption.

### Milestone 1 — name authority and refuse-then-apply sidecar migration

Scope: introduce one module owning every sidecar name, switch the context/workspace ledgers
and both cabal fragments to the new names, and extend the existing name-migration rail so a
tree carrying old-name sidecars refuses until `--apply-name-migrations` moves them. At the end
of this milestone a fresh scaffold emits only new names, and an old-name tree migrates loudly
and losslessly. The conformance ledger is untouched until M2.

Create `keiro-dsl/src/Keiro/Dsl/SidecarNames.hs` exporting the six current-name helpers —
`contextLedgerFileName :: Text -> FilePath`, `workspaceLedgerFileName :: Text -> FilePath`,
`conformanceLedgerFileName :: FilePath`, `contextCabalFragmentFileName :: Text -> FilePath`,
`workspaceCabalFragmentFileName :: Text -> FilePath`,
`workspaceMigrationReportFileName :: Text -> FilePath` — and the legacy-name helpers the
migration and adoption paths need — `legacyContextRecordFileName`,
`legacyWorkspaceRecordFileName`, `legacyConformanceRecordFileName`,
`legacyContextManifestFileName`, `legacyWorkspaceManifestFileName`. Register the module in
`keiro-dsl/keiro-dsl.cabal`'s `exposed-modules`. Rewire the existing helpers to delegate:
`Keiro.Dsl.ScaffoldRecord.recordFileName`,
`Keiro.Dsl.WorkspaceRecord.workspaceRecordFileName`,
`Keiro.Dsl.WorkspaceRecord.workspaceManifestFileName` (rename its export to match the
fragment vocabulary or re-export from `SidecarNames`; update the three doc comments beside
them), `Keiro.Dsl.ConformancePackage.conformanceRecordFileName` (delegation only in M1 — the
value stays `keiro-dsl-conformance-record.txt` until M2), and replace the inline literal at
`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs:571` with `contextCabalFragmentFileName`.

Add the migration step. Define a small sidecar-move type (old path, new path, disposition) in
`SidecarNames` or a new `Keiro.Dsl.SidecarMigration` module with a pure planner and an IO
applier:

- Planning runs at the very start of both scaffold entry points — before
  `readWorkspaceRecord` at `keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs:404` and before the
  record read in `executeServiceScaffoldWithRuntimePackageAndNameMigrations` — so an
  old-name-only tree can never be read as fresh. For each sidecar family it inspects the
  output directory: old name present and new name absent plans a *rename*; old and new both
  present plans a *retirement* of the old file into the backup slot
  `.keiro-dsl-name-migrations/sidecar-v1/<old-name>` (the sibling of the source-move backup
  slot at `keiro-dsl/src/Keiro/Dsl/HaskellSourceMove.hs:89`), keeping the new file
  authoritative while preserving the old bytes for inspection.
- `Refusal` in `Keiro.Dsl.ScaffoldRun` gains a `SidecarMigrationRequired` constructor
  carrying the planned moves. Rendering mirrors the source-move remediation
  (`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs:930`): list each move as `old -> new` (or
  `old -> retired to <backup>`) and end with "re-run scaffold with --apply-name-migrations
  after reviewing these sidecar renames:". Extending `Refusal` is a breaking library change;
  record it in the CHANGELOG entry written in M3.
- When `--apply-name-migrations` is passed, apply the moves (an atomic `renameFile` per move;
  create the backup directory for retirements), report each applied move in the scaffold
  output, then continue the run, which now reads the new-name ledger and reports
  stale/drift/ownership exactly as a pre-rename run would. A second run plans no moves and
  reports nothing — idempotence.
- Cabal fragments are write-only, so their old files would otherwise be left as orphans; the
  planner includes them (rename when only old exists, retirement when both exist) purely so
  no stale old-name file remains to mislead a reader. The migration report file keeps its
  name and needs no move.

Teach adoption the new standalone name. In `Keiro.Dsl.WorkspaceAdoption`, everywhere the
legacy context record is located via `recordFileName context`
(`keiro-dsl/src/Keiro/Dsl/WorkspaceAdoption.hs:151` and `:172`), look for
`contextLedgerFileName context` first and fall back to `legacyContextRecordFileName context`.
This is not the deprecated fallback-read pattern: adoption is definitionally the
legacy-import path, it may read historical names forever, and `markLegacyRecordSuperseded`
must mark whichever file the evidence actually came from. The `superseded-by:` marker's
meaning is unchanged.

Acceptance for M1: a fresh standalone scaffold writes `keiro-dsl-ledger.context.<context>.txt`
and `keiro-dsl-cabal-fragment.context.<context>.txt`; a fresh workspace scaffold writes the
`workspace`-slot equivalents; re-running over a tree prepared with old names refuses with the
move list and writes nothing; re-running with `--apply-name-migrations` migrates, after which
stale/drift/ownership-move reports over a mutated spec are byte-identical to what the same
mutation reported before the rename; a third run plans nothing.

### Milestone 2 — conformance ledger name and durability contract

Scope: rename the conformance ledger to `keiro-dsl-conformance-ledger.txt` and rebuild its
format on the workspace ledger's conventions, converting legacy files during the same
migration apply step. At the end of this milestone every machine-read sidecar shares one
durability contract.

In `Keiro.Dsl.ConformancePackage`, replace the renderer and parser:

- New format: a versioned header line `keiro-dsl conformance ledger v1`, scalar rows
  `service-key workspace <service>` / `service-key standalone <context>`,
  `runtime-package <name>`, `facade-module <module>`, and one typed row per file:
  `file {"kind":"generated","path":"..."}` or `file {"kind":"create-once","path":"..."}`
  as canonical single-line JSON, following the `module {...}` row precedent documented at
  `keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs:39-45`.
- Parser rules: unknown row kinds are ignored; unknown JSON keys inside known rows are
  ignored; there is no row-count check and no `schema` scalar row (the header line carries
  the version). Keep, verbatim in behavior: the service-key mismatch refusal
  (`ConformancePackageRecordMismatch`), `safeRelativePath` rejection of absolute or
  `..`-bearing paths, and the case-folded duplicate-path rejection currently in `safeFiles`
  (`keiro-dsl/src/Keiro/Dsl/ConformancePackage.hs:352-354`). A missing ledger still means
  "no history", and an unparsable ledger is still the hard refusal
  `InvalidConformancePackageRecord` — tolerance is for *unknown extensions*, not corruption.
- JSON `path` payloads round-trip any legal relative path, including one containing a space;
  the old three-token `T.words` trap disappears structurally. Scalar rows carry only lexed
  identifiers and Haskell module/package names, which cannot contain whitespace.
- Keep the legacy parser under a `Legacy` name solely for migration conversion, and keep
  `isGeneratedBannerLine` handling as it is.

Extend the M1 migration planner: inside each planned conformance package directory, an old
`keiro-dsl-conformance-record.txt` plans a *conversion* move — parse with the legacy parser,
render in the new format, write `keiro-dsl-conformance-ledger.txt`, retire the old file to
the sidecar backup slot. An unparsable legacy file is a refusal naming the file, never a
silent fresh start. Switch `conformanceRecordFileName` (delegated through `SidecarNames`
since M1) to the new name and update `readPreviousRecord` and the writer.

Acceptance for M2: a conformance ledger carrying an unrecognized future row kind and an
unrecognized JSON key inside a `file` row parses, round-trips its known rows unchanged, and
does not refuse the run; a service-key mismatch still refuses; a legacy-format record is
converted during `--apply-name-migrations` with byte-preserved backup; a `file` row whose
path contains a space round-trips through render-then-parse.

### Milestone 3 — sweep, regressions, documentation, distillation

Scope: move every remaining literal, refresh committed fixtures, add the regression suite,
document the sidecars, and distill the durable decisions. At the end of this milestone the
whole test suite asserts the new names and a novice can learn the sidecar roles from the user
guide.

Update the 14 name mentions in `keiro-dsl/test/Main.hs` and any in other suites to the
`SidecarNames` helpers rather than fresh literals. Rename or regenerate committed fixture
sidecars (at minimum the conformance record under
`keiro-dsl/test/conformance-service-package/runtime/src/keiro-dsl-conformance.workspace.workspace-proof/`
and the record/manifest pair under `keiro-dsl/test/conformance-aggregate-scalars/`),
regenerating rather than hand-editing wherever a suite can rebuild them. Add regressions for:
old-name-only tree refuses without the flag and migrates with it, with post-migration
stale/drift reports equal to pre-rename baselines; migration idempotence (second apply plans
nothing); both-names-present retirement to the backup slot; adoption over a tree whose
context history sits under either the legacy record name or the new context-ledger name;
unknown-row and unknown-key tolerance plus service-key mismatch refusal in the conformance
ledger; awkward-path round-tripping; and non-collision for a context literally named
`workspace`.

Update `docs/user/typed-spec-toolchain.md` (mentions at lines 1304, 1346, 1395): describe the
four sidecars by role — two ledgers the tool owns, one cabal fragment the human pastes, one
migration report the human reads once — and add an old-to-new glossary table. Historical
documents under `docs/plans/` keep the old names. Add the CHANGELOG entry under Breaking
Changes in `keiro-dsl/CHANGELOG.md`: the rename table, the `Refusal` constructor addition,
the conformance ledger format change, and the observable first-run behavior (refusal listing
sidecar renames; `--apply-name-migrations` applies them losslessly).

Distill: allocate the next ADR handle with `okf id next docs/adr --profile docs/adr/profile.dhall`
and record the sidecar naming contract (one meaning per word; `ledger`/`cabal-fragment`
stems; explicit slot segments; refuse-then-apply migration for sidecar renames; the
`superseded-by:` marker remains adoption-only). Update
`docs/adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md`
where it names the old workspace record file, run the strict profile validation from the
skill's ADR workflow, and maintain `docs/adr/log.md`. Mark IR-19 completed (frontmatter
`status`, body Status section, `docs/improvement-requests/log.md` entry) in the same change.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless noted.

Build and core suites after each milestone:

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test
```

The scaffold/workspace behavior lives in `keiro-dsl-test`; expect output ending in
`All <N> tests passed` (the suite prints tasty-style dots per group). After M2 also run the
conformance package suites that exercise committed sidecars:

```bash
cabal test keiro-dsl-conformance keiro-dsl-conformance-aggregate-scalars
```

Manual end-to-end check after M1 (uses the committed fixture spec; the output directory is
disposable):

```bash
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/aggregate-scalars.keiro --out /tmp/keiro-sidecar-demo
ls /tmp/keiro-sidecar-demo
```

Expected listing includes `keiro-dsl-ledger.context.<context>.txt` and
`keiro-dsl-cabal-fragment.context.<context>.txt` and no `keiro-dsl-scaffold-record.*` or
`keiro-dsl-manifest.*` file. Then simulate an old tree and observe the refusal and the
migration:

```bash
mv /tmp/keiro-sidecar-demo/keiro-dsl-ledger.context.<context>.txt \
   /tmp/keiro-sidecar-demo/keiro-dsl-scaffold-record.<context>.txt
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/aggregate-scalars.keiro --out /tmp/keiro-sidecar-demo
```

Expected: a refusal listing
`keiro-dsl-scaffold-record.<context>.txt -> keiro-dsl-ledger.context.<context>.txt` and the
remediation line naming `--apply-name-migrations`; the tree is unchanged. Re-run with the
flag and expect the move to be reported, the run to complete, and a further run to report an
unchanged tree with no migration lines.

Full-suite gate before completing M3 (long; run once the sweep is done):

```bash
cabal test all
```

Strict validation for the bundles touched in M3:

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall
```


## Validation and Acceptance

Acceptance restates revised IR-19's criteria as observable behavior:

1. After a fresh scaffold, no sidecar name states a role the file does not have, and the
   machine-read ledgers are distinguishable from human-facing output by name alone
   (`keiro-dsl-ledger.*` / `keiro-dsl-conformance-ledger.txt` versus
   `keiro-dsl-cabal-fragment.*` / `keiro-dsl-migration-report.*`).
2. A scaffold run over a directory containing only old-name sidecars refuses, listing every
   planned move, and writes nothing — the tree, both ledgers, and the fragment are untouched
   by a refusal.
3. `scaffold --apply-name-migrations` over that directory performs the moves; afterwards
   stale, drift, and ownership-move reporting over the same mutation is identical to a
   pre-rename run, no old-name file remains in the tree (renamed, or retired byte-identically
   under `.keiro-dsl-name-migrations/sidecar-v1/`), and a re-run plans nothing.
4. The conformance ledger parser accepts a record carrying an unrecognized future row and an
   unrecognized JSON key, round-trips its known rows unchanged, and still refuses a
   service-key mismatch. A `file` path containing a space round-trips; absolute and
   `..`-bearing paths are still rejected.
5. Adoption still imports pre-workspace history whether the context ledger sits under its
   legacy or current name, appending its `superseded-by:` marker to the file actually read.
6. `cabal test all` passes; `keiro-dsl/test/Main.hs` asserts the new names via the
   `SidecarNames` helpers; the regressions named in M3 exist and pass.
7. `docs/user/typed-spec-toolchain.md` documents the sidecars by role with the old-to-new
   glossary, and `keiro-dsl/CHANGELOG.md` records the breaking rename, the `Refusal`
   extension, the conformance format change, and the first-run migration behavior.


## Idempotence and Recovery

Every step is re-runnable. The migration planner is pure and the apply step is per-file
`renameFile`, so an interrupted apply leaves each sidecar either at its old or its new path;
the next run plans only the remaining moves. Retirements preserve the old bytes under
`.keiro-dsl-name-migrations/sidecar-v1/`, so any migrated or retired file can be restored by
copying it back. The conformance-ledger conversion writes the new file before retiring the
old one, so a crash between the two leaves both present, which the next planner run treats as
a retirement. Committed fixture updates are ordinary git changes; `git checkout -- keiro-dsl/test`
restores them. No step deletes information: renames preserve bytes, retirements preserve
bytes in the backup slot, and refusals write nothing.


## Interfaces and Dependencies

No new external dependencies. At the end of the plan these interfaces exist:

- `Keiro.Dsl.SidecarNames` (new, exposed): `contextLedgerFileName :: Text -> FilePath`,
  `workspaceLedgerFileName :: Text -> FilePath`, `conformanceLedgerFileName :: FilePath`,
  `contextCabalFragmentFileName :: Text -> FilePath`,
  `workspaceCabalFragmentFileName :: Text -> FilePath`,
  `workspaceMigrationReportFileName :: Text -> FilePath`, and the `legacy*FileName`
  counterparts for the five renamed sidecars.
- `Keiro.Dsl.ScaffoldRun.Refusal` gains `SidecarMigrationRequired` carrying the planned
  sidecar moves (breaking; exhaustive matches must be extended).
- The sidecar migration planner/applier (in `Keiro.Dsl.SidecarNames` or a dedicated
  `Keiro.Dsl.SidecarMigration`), invoked from
  `Keiro.Dsl.WorkspaceScaffold.executeWorkspaceScaffoldWithNameMigrations` and
  `Keiro.Dsl.ScaffoldRun.executeServiceScaffoldWithRuntimePackageAndNameMigrations` before
  any ledger read, gated by the existing `--apply-name-migrations` switch.
- `Keiro.Dsl.ConformancePackage`: `renderConformancePackageRecord` and
  `parseConformancePackageRecord` rebuilt on the header-plus-typed-JSON-rows conventions;
  a `Legacy`-named parser retained for conversion; `conformanceRecordFileName` returning
  `keiro-dsl-conformance-ledger.txt` via `SidecarNames`.
- `Keiro.Dsl.WorkspaceAdoption` locating context history under the current name first and
  the legacy name second, with `markLegacyRecordSuperseded` marking the file actually read.


## Revision Notes

- 2026-08-05: Completed all milestones after the full all-package suite, focused generated
  conformance suites, strict OKF validation, and byte-clean 41-invocation corpus replay.
  Recorded the explicit backup-conflict rule, retained standalone/workspace ledger bytes,
  accepted ADR 0022, amended ADR 0015, and closed IR-19.
