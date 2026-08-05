---
type: Improvement Request
title: Give keiro-dsl generated sidecars honest names and one durability contract
description: >-
  Rename the scaffolder's generated sidecar files so each name states whether keiro-dsl or a human
  owns it, migrate existing history loudly through the refuse-then-apply rail without losing it,
  and hold the conformance package record to the workspace record's forward-compatibility contract.
timestamp: 2026-08-05T12:55:00Z
requestId: IR-19
status: planned
origin: mori://shinzui/keiro
plan: docs/plans/198-rename-keiro-dsl-sidecars-to-explicit-slot-ledger-names-with-one-durability-contract.md
---

# Improvement Request: Give keiro-dsl Generated Sidecars Honest Names and One Durability Contract

## Status

**Planned.**
[Plan 198](../plans/198-rename-keiro-dsl-sidecars-to-explicit-slot-ledger-names-with-one-durability-contract.md)
under [MasterPlan 29](../masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md) implements this
request in the current breaking release window.

Revised 2026-08-05 during planning review. The diagnosis and goal are unchanged; the requested
solution changed in three ways, each recorded with rationale in Plan 198's Decision Log. First,
the machine-owned stem is `ledger`, not `lock`: a lockfile's defining ecosystem property is that
it is safely regenerable, and these files are precisely the ones whose deletion silently destroys
history, so `lock` would state a role the file does not have. Second, the workspace and context
slots are distinct literal segments (`.workspace.` / `.context.`) rather than being distinguished
by segment count, and the conformance ledger keeps a qualifier, so collision-freedom is by
construction and needs no header-comment proof. Third, migration rides the existing
refuse-then-apply `--apply-name-migrations` rail as a lossless file move instead of a silent
old-name fallback read with a permanent `superseded-by:` marker: the refusal enforces the
never-present-as-fresh invariant more strongly, leaves no zombie files, resolves the
both-names-exist case explicitly, and keeps the `superseded-by:` marker meaning exactly one
thing — context history adopted into a workspace.

It does not change generated-service runtime behavior, but it does change the scaffolder's
on-disk output names, so it must land in a breaking release. The current `Unreleased` window
already carries generated-name breaking changes, which makes it the cheapest place to spend this
one.

## Context

A scaffold run emits four sidecar files. Two are read back by later runs and two are never parsed —
and the names invert the distinction.

Machine-read, on every subsequent run:

- `keiro-dsl-scaffold-record.workspace.<service>.txt` and `keiro-dsl-scaffold-record.<context>.txt`
  — the ownership ledger, read by `readWorkspaceRecord`
  (`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs:404`) and `readRecord`
  (`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs:817`). It carries the emitted file list with kinds,
  owners, roles, mappings, and bindings, and it is what drives stale detection, mapping and
  behavior drift, and ownership-move reporting.
- `keiro-dsl-conformance-record.txt` — the conformance package's own ledger, read by
  `readPreviousRecord` (`keiro-dsl/src/Keiro/Dsl/ConformancePackage.hs:372`).

Never parsed:

- `keiro-dsl-manifest.<workspace-or-context>.txt` — a Cabal fragment for a human to paste into the
  consuming stanza (`keiro-dsl/src/Keiro/Dsl/Manifest.hs:70-73`). `Keiro.Dsl.Manifest` exports only
  renderers and contains no parser, and nothing anywhere reads the file back.
- `keiro-dsl-migration-report.workspace.<service>.txt` — the one-shot legacy-adoption report.

So the file named `manifest` is the human sheet, and the files named `record` are the manifests. A
third, unrelated artifact compounds it: the hand-authored `service.keiro-workspace` input, parsed by
`parseWorkspaceManifest` (`keiro-dsl/src/Keiro/Dsl/Workspace.hs:1244`), is also called a manifest in
prose and in the `manifestPath` identifiers throughout `Keiro.Dsl.Workspace`. One word carries three
meanings across authored input, machine-read ledger, and human report.

The two machine-read ledgers are also held to different durability contracts.

The workspace record was designed for cross-version safety (`keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs:1-44`):
a versioned header, typed rows with canonical single-line JSON payloads, an explicit policy that
unknown row kinds and unknown JSON keys are ignored, and rejection of absolute or `..`-bearing paths
before they are joined to an output root (`:305-311`). An older binary is structurally incapable of
clobbering newer history.

The conformance record has none of that:

- `knownRows == length rows` (`keiro-dsl/src/Keiro/Dsl/ConformancePackage.hs:333-335`) invalidates
  the entire record on any unrecognized row, and `schema == 1` is an exact match. Adding a row in
  any future version therefore makes older binaries fail — and per `:363-365` that is a hard refusal
  of the whole scaffold run, not a warning.
- Rows are whitespace-split (`T.words`, `:345`) with `parseFile ["file", kind, path]` matching
  exactly three tokens, so a path containing a space yields an unparsable record. Not reachable
  today, since all four paths are keiro-dsl-generated and space-free, but it is a latent trap the
  JSON-row format does not have.
- An invalid or key-mismatched record is a refusal (`:381-384`), whereas a *missing* workspace record
  simply means "no history".

Renaming carries a hazard that must be part of the change rather than a follow-up.
`readWorkspaceRecord` resolves an exact path (`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs:414`).
Under a new name, an established output tree presents as fresh: `previous` is `Nothing`, so stale
detection, drift, and ownership-move reporting all go **silent**, and the adoption branch
(`:444-446`) can fire and claim already-generated files by banner — writing a migration report and
appending a `superseded-by:` line to a legacy record. No refusal, no warning, which is the worst
failure shape for a tool whose entire value here is knowing what it previously owned.

Churn is small. There are 14 hardcoded sidecar-name literals across `keiro-dsl/src`, `keiro-dsl/app`,
and `keiro-dsl/test` (three of which are the defining helpers), 14 mentions in
`keiro-dsl/test/Main.hs`, and 3 in `docs/user/typed-spec-toolchain.md`. The risk is the silent
history loss above, not the edit volume.

## Requested Change

Adopt one rule for these names: one meaning per word. `ledger` names a machine-owned machine-read
file, `manifest` names only the artifact a human authors, and every other name states what a human
does with the file. `lock` is deliberately not used: a lockfile is regenerable by convention, and
these files are not — deleting one destroys the run history the tool exists to keep.

1. Rename the sidecars, keeping the `.txt` extension:

   | Current | Requested |
   | --- | --- |
   | `keiro-dsl-scaffold-record.workspace.<service>.txt` | `keiro-dsl-ledger.workspace.<service>.txt` |
   | `keiro-dsl-scaffold-record.<context>.txt` | `keiro-dsl-ledger.context.<context>.txt` |
   | `keiro-dsl-conformance-record.txt` | `keiro-dsl-conformance-ledger.txt` |
   | `keiro-dsl-manifest.workspace.<service>.txt` | `keiro-dsl-cabal-fragment.workspace.<service>.txt` |
   | `keiro-dsl-manifest.<context>.txt` | `keiro-dsl-cabal-fragment.context.<context>.txt` |
   | `keiro-dsl-migration-report.workspace.<service>.txt` | unchanged — already accurate |

   The slot is an explicit literal segment — `.workspace.` or `.context.` — so the two ledger
   namespaces cannot collide by construction, even for a context literally named `workspace`, and
   no header-comment collision proof is needed. The conformance ledger keeps its qualifier so its
   name is meaningful without knowing which directory it was found in and the ledger family stays
   greppable. `ledger` carries the conventions that follow — committed, machine-owned, not
   hand-edited, expected in the diff, never discarded — and using it for all three machine-read
   files makes them visibly one family, which nothing signals today.

   Keep `.txt`. `.jsonl` would be untrue — scalar rows are not JSON, only the typed row payloads
   are — and the line-oriented format exists precisely so appends are safe and old parsers
   tolerate new rows. Audience belongs in the stem.

2. Migrate loudly through the rail this release window already established for generated-name
   moves. A scaffold run over a tree carrying old-name sidecars refuses with the exact rename
   plan and writes nothing; `scaffold --apply-name-migrations` performs the moves as lossless
   file renames, retiring a duplicate old file byte-identically into the name-migration backup
   slot when both names exist, and reports each applied move. A directory holding only old-name
   ledgers must never be treated as fresh — the refusal enforces this invariant structurally.
   Silent fallback reading of old names is explicitly not wanted, and sidecar migration must not
   write `superseded-by:` markers, which remain the adoption path's evidence trail. Adoption
   itself — the deliberate legacy-import path — reads context history under the current name
   first and the legacy name second, forever.

3. Give the conformance record the workspace record's contract: a versioned header line, typed
   rows with single-line JSON payloads, unknown rows and unknown keys ignored, and no
   exact-row-count check. Keep the service-key mismatch refusal, which is a real guard rather
   than a compatibility accident, and keep unsafe-path rejection. Convert legacy-format records
   during the same `--apply-name-migrations` step; the rename already makes the file invisible
   to older binaries, so one compatibility break covers both.

4. Preserve ledger content and every existing safety property: the never-delete rule for
   consumer-owned files, stale reporting with banner evidence, the missing-`@generated`-banner
   refusal, create-once `HoleStub` skipping, and unsafe-path rejection.

Out of scope, and deliberately so: replacing the pasted Cabal fragment with a build-readable
`.cabal` or project fragment. That is a larger change to how consumers wire generated modules, it is
independent of naming, and folding it in would couple a cheap rename to a real design question.

## Acceptance

1. No generated sidecar name states a role the file does not have, and the machine-read ledgers are
   distinguishable from human-facing output by name alone.
2. A scaffold run over a directory containing only old-name sidecars refuses, listing every planned
   move with a remediation line naming `--apply-name-migrations`, and leaves the tree, both
   ledgers, and the Cabal fragment untouched.
3. `scaffold --apply-name-migrations` over that directory performs the moves; afterwards stale,
   drift, and ownership-move reporting are identical to a pre-rename run over the same tree, no
   old-name sidecar remains in the tree, any retired duplicate is preserved byte-identically in
   the backup slot, and a re-run plans nothing further.
4. The conformance ledger parser accepts a record carrying an unrecognized future row and an
   unrecognized JSON key, and round-trips its known rows unchanged.
5. A conformance ledger whose service key does not match the plan is still a refusal, and a
   scaffold refusal still writes nothing.
6. Paths that are legal but awkward — a space among them — either round-trip through both ledgers
   or are rejected as unsafe paths with a diagnostic. Neither ledger can be rendered into a form
   its own parser rejects.
7. Adoption still imports pre-workspace context history under either its legacy or current name,
   appending its `superseded-by:` marker to the file actually read.
8. The library, CLI, scaffold, workspace, and full suites pass; `keiro-dsl/test/Main.hs` asserts
   the new names; and regressions cover the old-name refusal, the applied migration, and its
   idempotence.
9. `docs/user/typed-spec-toolchain.md` documents the four sidecars by role and carries an
   old-to-new glossary. Historical documents under `docs/plans/` keep the old names, since they
   record what was decided at the time.
10. `keiro-dsl/CHANGELOG.md` records the rename as a breaking change and states the refusal and
    migration behavior a consumer will observe on first run.

## Requested Deliverables

- Renamed sidecars resolved through a single-source name-helper module, replacing the scattered
  literals.
- A `SidecarMigrationRequired` refusal and `--apply-name-migrations` sidecar move covering
  rename, duplicate retirement, and legacy conformance-format conversion.
- Conformance ledger renderer and parser rebuilt on the workspace record's row conventions.
- Regressions for: old-name refusal and applied migration, migration idempotence, duplicate
  retirement, dual-name adoption, unknown-row and unknown-key tolerance, service-key mismatch
  refusal, and awkward-path round-tripping.
- A user-guide section describing the sidecars by role, plus the old-to-new glossary.
- A CHANGELOG breaking-change entry covering the rename, the refusal, and the migration behavior.
