---
type: Improvement Request
title: Give keiro-dsl generated sidecars honest names and one durability contract
description: >-
  Rename the scaffolder's generated sidecar files so each name states whether keiro-dsl or a human
  owns it, migrate existing history without silently losing it, and hold the conformance package
  record to the workspace record's forward-compatibility contract.
timestamp: 2026-08-05T04:37:18Z
requestId: IR-19
status: proposed
origin: mori://shinzui/keiro
---

# Improvement Request: Give keiro-dsl Generated Sidecars Honest Names and One Durability Contract

## Status

Proposed as a developer-experience and durability improvement in `keiro-dsl`. It does not change
generated-service runtime behavior, but it does change the scaffolder's on-disk output names, so it
must land in a breaking release. The current `Unreleased` window already carries generated-name
breaking changes, which makes it the cheapest place to spend this one.

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
and `keiro-dsl/test` (three of which are the defining helpers), 10 mentions in
`keiro-dsl/test/Main.hs`, and 3 in `docs/user/typed-spec-toolchain.md`. The risk is the silent
history loss above, not the edit volume.

## Requested Change

Adopt one rule for these names: one meaning per word. `lock` names a machine-owned ledger,
`manifest` names only the artifact a human authors, and every other name states what a human does
with the file.

1. Rename the sidecars, keeping the `.txt` extension:

   | Current | Requested |
   | --- | --- |
   | `keiro-dsl-scaffold-record.workspace.<service>.txt` | `keiro-dsl-lock.workspace.<service>.txt` |
   | `keiro-dsl-scaffold-record.<context>.txt` | `keiro-dsl-lock.<context>.txt` |
   | `keiro-dsl-conformance-record.txt` | `keiro-dsl-lock.txt` (inside the package directory) |
   | `keiro-dsl-manifest.<workspace-or-context>.txt` | `keiro-dsl-cabal-fragment.<workspace-or-context>.txt` |
   | `keiro-dsl-migration-report.workspace.<service>.txt` | unchanged — already accurate |

   `lock` is the honest word: the file records the last successful run so the next run can diff its
   plan against it, and it carries the conventions that follow — committed, machine-owned, not
   hand-edited, expected in the diff. Using it for both ledgers makes them visibly one family, which
   nothing signals today. The conformance ledger drops its qualifier because it already sits inside
   `keiro-dsl-conformance.<slot>/` and is alone there.

   Keep `.txt`. `.jsonl` would be untrue — `service:` and `member` rows are not JSON, only the
   `module`, `mapping`, `binding`, and `adopted` payloads are — and the line-oriented format exists
   precisely so appends are safe and old parsers tolerate new rows. Audience belongs in the stem.

2. Migrate without losing history. Read the new name; on absence fall back to the old name; write
   only the new name; append a `superseded-by:` line to the old file, reusing
   `markLegacyRecordSuperseded` (`keiro-dsl/src/Keiro/Dsl/WorkspaceAdoption.hs:169-184`), which is
   idempotent by inspection and whose marker the v1 parser already ignores; and report the one-time
   migration in the scaffold output. A directory holding only an old-name record must never be
   treated as fresh.

3. Restate the collision proof rather than inheriting it. The current argument
   (`keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs:9-19`) is that a context name cannot contain a dot,
   so the `.workspace.` slot cannot collide. Under the new stem the workspace and context slots are
   separated by segment count — `keiro-dsl-lock.workspace.<service>.txt` versus
   `keiro-dsl-lock.workspace.txt` for a context literally named `workspace` — so the header comment
   must say that explicitly.

4. Give the conformance record the workspace record's contract: typed rows with single-line JSON
   payloads, unknown rows and unknown keys ignored, and no exact-row-count check. Keep the
   service-key mismatch refusal, which is a real guard rather than a compatibility accident. If
   `cprSchema` is to be bumped, bump it in this change: the rename already makes the file invisible
   to older binaries, so one compatibility break should cover both.

5. Preserve ledger content and every existing safety property: the never-delete rule, stale
   reporting with banner evidence, the missing-`@generated`-banner refusal, create-once `HoleStub`
   skipping, and unsafe-path rejection.

Out of scope, and deliberately so: replacing the pasted Cabal fragment with a build-readable
`.cabal` or project fragment. That is a larger change to how consumers wire generated modules, it is
independent of naming, and folding it in would couple a cheap rename to a real design question.

## Acceptance

1. No generated sidecar name states a role the file does not have, and the machine-read ledgers are
   distinguishable from human-facing output by name alone.
2. A scaffold run over a directory containing only old-name records reads that history: stale, drift,
   and ownership-move reporting are identical to a pre-rename run over the same tree, and no
   migration report is written.
3. After migration the new-name ledger exists, the old-name file carries exactly one
   `superseded-by:` line, no file has been deleted, and a re-run appends nothing further.
4. The conformance record parser accepts a record carrying an unrecognized future row and an
   unrecognized JSON key, and round-trips its known rows unchanged.
5. A conformance record whose service key does not match the plan is still a refusal, and a scaffold
   refusal still leaves the tree, both ledgers, and the Cabal fragment untouched.
6. Paths that are legal but awkward — a space among them — either round-trip through both ledgers or
   are rejected as unsafe paths with a diagnostic. Neither ledger can be rendered into a form its
   own parser rejects.
7. The library, CLI, scaffold, workspace, and full suites pass; `keiro-dsl/test/Main.hs` asserts the
   new names; and a regression covers the old-to-new fallback with its supersession marker.
8. `docs/user/typed-spec-toolchain.md` documents the four sidecars by role and carries an
   old-to-new glossary. Historical documents under `docs/plans/` keep the old names, since they
   record what was decided at the time.
9. `keiro-dsl/CHANGELOG.md` records the rename as a breaking change and states the fallback
   behavior a consumer will observe on first run.

## Requested Deliverables

- Renamed sidecars resolved through single-source name helpers, replacing the 14 scattered literals.
- Old-name fallback with one-time supersession and a scaffold-report line naming the migration.
- Conformance record renderer and parser rebuilt on the workspace record's row conventions.
- Regressions for: old-name fallback, idempotent supersession, unknown-row and unknown-key
  tolerance, service-key mismatch refusal, and awkward-path round-tripping.
- A user-guide section describing the sidecars by role, plus the old-to-new glossary.
- A CHANGELOG breaking-change entry covering the rename and the migration behavior.
