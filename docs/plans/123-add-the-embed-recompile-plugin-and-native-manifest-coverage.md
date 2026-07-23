---
id: 123
slug: add-the-embed-recompile-plugin-and-native-manifest-coverage
title: "Add the embed recompile plugin and native manifest coverage"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
intention: intention_01ky8hzdgxe7etqkgzfma64nj5
master_plan: "docs/masterplans/19-restore-the-migration-integrity-gates-under-pg-migrate-surfaced-by-the-2026-07-migration-review.md"
---

# Add the embed recompile plugin and native manifest coverage

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

keiro's migrations are compiled into the binary: a Template Haskell splice reads the
ordered manifest file `keiro-migrations/migrations/manifest`, validates that the manifest
and the `migrations/` directory agree exactly, and embeds every SQL file's bytes. Two
build-time integrity gaps survived the codd-to-pg-migrate swap.

First (finding MIG-4): GHC 9.12 has no way to register a *directory* as a Template Haskell
dependency, so the strict manifest-membership check only reruns when GHC actually
recompiles the embedding module. A developer who adds `0019-….sql` but forgets the manifest
line keeps getting green incremental builds with a stale embed that silently omits the new
migration. kiroku's equivalent module already carries the pg-migrate-embed
`RecompilePlugin` pragma that mitigates this; keiro's does not, even though
pg-migrate-embed's own documentation says GHC 9.12 users should load it.

Second (finding MIG-7): the repo-side tamper check pins only the 16 legacy-parity migration
files byte-for-byte (against `keiro-migrations/migrations.lock`, which is really codd-cutover
evidence). The native-era migrations `0017-schema-management-comment.sql` through
`0020-keiro-workflow-children-failure-reason.sql` — and every future one — are in no
repo-side checksum manifest. Runtime checksum keying still catches an edit, but only at
deploy time as a `PlanVerificationFailed` outage on every already-migrated database,
instead of at review time as a CI failure.

After this plan: the pragma is in place (with an honest account of what it does and does
not cover, demonstrated by a reproduction transcript), and a new native lockfile
`keiro-migrations/migrations.native.lock` pins every native migration byte-for-byte in the
default test suite, so editing a shipped migration or adding an unlisted SQL file fails
`cabal test keiro-migrations-test` — which is what `just verify` (this repository's CI
gate) runs. The master plan sizes this plan at roughly an afternoon; keep it that small.


## Progress

- [x] (2026-07-23T23:16:24Z) Milestone 1: `RecompilePlugin` pragma and comment added to keiro's embed module; stale-embed hazard reproduced pre-fix and shown caught post-fix; the no-GHC residual reproduced; default migration suite passed (20 examples, 0 failures).
- [ ] Milestone 2: `migrations.native.lock` checked in covering all 20 native files; suite test asserts lockfile/manifest/directory/bytes four-way agreement; `docs/user/migration-ownership.md` manifest statement updated; suite green.


## Surprises & Discoveries

- Discovery: The pre-fix incremental build reproduced the stale-embed hazard exactly. After
  a clean build, adding an unlisted `0099-stale-embed-drill.sql` and changing only
  `Keiro.Migrations` recompiled that module but not
  `Keiro.Migrations.Internal.Definition`; the build exited zero:

  ```text
  [2 of 5] Compiling Keiro.Migrations ... [Source file changed]
  exit 0
  ```

  With the plugin pragma installed, the same unlisted file plus a change to
  `Keiro.Migrations` forced the embedding module and failed before a stale component could
  be produced:

  ```text
  [1 of 5] Compiling Keiro.Migrations.Internal.Definition
      [Impure plugin forced recompilation]
  invalid pg-migrate manifest: UnlistedSqlFiles ["0099-stale-embed-drill.sql"]
  exit 1
  ```

  Finally, after a successful plugin-enabled build, adding only the unlisted SQL file and
  changing no Haskell source printed `Up to date` and exited zero. This confirms the
  documented residual: the plugin protects every build in which Cabal invokes GHC, while
  the native lockfile test must protect test runs where Cabal invokes no compiler.
  Date: 2026-07-23


## Decision Log

- Decision: Pin native migrations with a NEW lockfile (`keiro-migrations/migrations.native.lock`)
  rather than extending the existing `migrations.lock`, and prefer the lockfile over
  formally accepting runtime checksum keying as the only gate.
  Rationale: `migrations.lock` is not merely a test fixture — it is embedded into the
  library as codd-import evidence (`Keiro.Migrations.History.Codd.keiroCoddManifestText =
  $(embedTextFile "migrations.lock")`) and parsed by pg-migrate-import-codd's
  `parseCoddManifest`; the strict import path (`buildCoddEvidence`) requires the manifest's
  filename set to equal the selected legacy set exactly and fails with
  `CoddManifestHasUnexpected` on extras. Adding native entries to it would therefore break
  every production codd-history import, and the existing byte-parity test also depends on
  its legacy-only shape. A separate native lockfile is cheap, restores review-time
  detection (the master plan's stated preference), and — because its test reads the
  `migrations/` directory at *test runtime* — also closes the residual window Milestone 1's
  compiler plugin cannot (see next entry).
  Date: 2026-07-23

- Decision: Do not CI-automate the stale-embed reproduction; document it as a manual
  validation transcript in this plan instead.
  Rationale: Automating it would mean scripting two cabal builds with a source mutation in
  between and asserting on rebuild behavior — brittle, slow, and coupled to cabal's
  recompilation internals. The exposure is local/incremental artifacts only: clean CI
  builds (what `just verify` does from scratch, and any nix build) always rerun the splice,
  and Milestone 2's lockfile test independently detects an unlisted or unpinned SQL file at
  test runtime regardless of embed staleness.
  Date: 2026-07-23

- Decision: Mirror kiroku's pragma comment verbatim in spirit, including its honest caveat.
  Rationale: The plugin forces GHC to reconsider the embedding module on every build *in
  which GHC runs for this package*. When no Haskell source changed at all, cabal reports
  "Up to date" and never invokes GHC, so the plugin cannot help; kiroku's comment says
  exactly this, and repeating it prevents the pragma from being mistaken for a complete
  fix.
  Date: 2026-07-23

- Decision: Implement the native lockfile against the current 20-file manifest, including
  migrations 0019 and 0020 that landed after this plan was authored.
  Rationale: A build-integrity gate must cover the branch being shipped. Keeping the
  plan-authoring count of 18 would leave the newest snapshot and workflow-failure columns
  outside review-time checksum coverage.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Work happens in the keiro repository (working directory
`/Users/shinzui/Keikaku/bokuno/keiro`; paths below are repository-relative). Two sibling
checkouts are read-only references: pg-migrate at `/Users/shinzui/Keikaku/bokuno/pg-migrate`
(the local source of the pinned `pg-migrate` 1.1.0.0 family) and kiroku at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

`docs/adr/0002-keiro-owns-live-schema-verification-under-pg-migrate.md` is relevant.
It separates pg-migrate's ledger guarantee from Keiro-owned default-build gates and states
that the checks are defense in depth rather than substitutes for one another. This plan
extends that inventory with compile-time directory revalidation and review-time native
checksum coverage. ADR 0001 concerns PGMQ telemetry and is unrelated.

**The embed pipeline.** `keiro-migrations/src/Keiro/Migrations/Internal/Definition.hs`
contains the splice:

```haskell
embeddedMigrationEntries :: NonEmpty (FilePath, ByteString)
embeddedMigrationEntries =
    $(embedMigrationManifest "migrations/manifest")
```

`embedMigrationManifest` (pg-migrate-embed,
`/Users/shinzui/Keikaku/bokuno/pg-migrate/pg-migrate-embed/src/Database/PostgreSQL/Migrate/Embed/Manifest.hs`)
parses the manifest strictly (no blanks, no comments, `.sql` basenames only, no
duplicates), then checks the manifest against the directory both ways: a listed file that
does not exist is `MissingManifestFile`, and — the direction that matters here — any `.sql`
file present in the directory but absent from the manifest is `UnlistedSqlFiles`, failing
the build. It registers the manifest and every *listed* file with `addDependentFile`, so
edits to known files retrigger the splice. What it cannot register is the directory itself:
GHC 9.12 has no TH directory-dependency API. The library's haddock (Manifest.hs lines
68-73) therefore says GHC 9.12 users "should load"
`Database.PostgreSQL.Migrate.Embed.RecompilePlugin`, a no-op Core plugin whose only effect
is `pluginRecompile = const (pure ForceRecompile)` — every GHC run reconsiders the module,
reruns the splice, and thereby re-validates directory membership.

kiroku's twin module,
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store-migrations/src/Kiroku/Store/Migrations/Internal/Definition.hs`,
carries the pragma at line 8 with a five-line comment explaining the mechanism and its
limit (lines 2-7). keiro's module has neither — that asymmetry is the whole of MIG-4.

**The current tamper manifest.** `keiro-migrations/test/Main.hs` lines 56-62 ("preserves
every legacy payload byte recorded by migrations.lock") read each of the 16 legacy-parity
files from `keiro-migrations/migrations/` and assert its SHA-256 equals the entry recorded
in `keiro-migrations/migrations.lock` under the file's old codd-era timestamped name.
`migrations.lock` has exactly 16 entries (`sha256␣␣legacy-filename` lines) and is *also*
embedded as codd-import evidence — see the first Decision Log entry for why it must not
grow. Nothing pins `0017-schema-management-comment.sql` through
`0020-keiro-workflow-children-failure-reason.sql`, or any future native file. The suite's
checksum helper (`checksumText`, using pg-migrate's
`migrationFingerprint`, which is SHA-256) and its lockfile parser (`parseLockfile`) already
exist in `test/Main.hs` and are reused as-is.

**What runtime keying does and does not give.** pg-migrate stores each applied migration's
checksum in the `pgmigrate.migrations` ledger; on every run, `comparePlanWithLedger` fails
closed with `MigrationChecksumMismatch` (surfacing as `PlanVerificationFailed`) if a
shipped file was edited. That is strictly safer than codd's filename keying — but it fires
at deploy time against every already-migrated database (an outage), not at review time.
The lockfile restores the review-time gate; the runtime gate remains as defense in depth.

**How the suite runs.** The default suite is `keiro-migrations-test`
(`keiro-migrations/keiro-migrations.cabal` line 383; source `keiro-migrations/test/Main.hs`).
This repository has no `.github/` CI; the gate is `just verify`, whose last step is
`cabal test keiro-migrations-test`. The sibling plan
`docs/plans/122-restore-live-schema-verification-body-lint-and-the-startup-handshake-under-pg-migrate.md`
also edits `test/Main.hs` (new example groups) — additive in different `describe` blocks,
so coordination is merge-order only. Per the master plan, this plan owns the
manifest-coverage statement in `docs/user/migration-ownership.md` (the "The manifest …"
paragraph in its Framework Components section, and the Authoring section's enforcement
claims); the handshake/verify sections of `docs/user/migrations.md` and the cutover runbook
belong to the sibling plans and must not be touched here.


## Plan of Work

Two milestones. Each leaves `cabal test keiro-migrations-test` green.

### Milestone 1 — the RecompilePlugin pragma and the honest reproduction (MIG-4)

Scope: one pragma plus comment in the embed module, and a recorded demonstration that the
hazard is real pre-fix and caught post-fix.

Edit `keiro-migrations/src/Keiro/Migrations/Internal/Definition.hs`. Directly below the
existing `{-# LANGUAGE TemplateHaskell #-}` line, add the comment and pragma, mirroring
kiroku:

```haskell
{-# LANGUAGE TemplateHaskell #-}
-- GHC 9.12 has no Template Haskell directory-dependency API, so a sibling SQL
-- file that is added or removed without being listed in the manifest leaves this
-- module looking up to date and silently skips manifest membership validation.
-- The plugin forces GHC to reconsider this module on every build it runs.
-- Note this cannot help when no Haskell source changes at all: cabal then
-- reports "Up to date" and never invokes GHC. A clean build revalidates, and
-- the migrations.native.lock suite test checks directory membership at test
-- runtime regardless.
{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}
```

No cabal change is needed: the plugin module ships in `pg-migrate-embed`, which the library
already depends on, and `-fplugin` loads it from that dependency.

Then perform the reproduction, in three phases, and paste the real transcripts into the
Surprises & Discoveries section (replace the expected transcripts shown in Concrete Steps
with what you actually observed if they differ — differences are findings).

Phase A (pre-fix hazard, run BEFORE committing the pragma, or with the pragma temporarily
commented out): build clean; drop an unlisted SQL file into the migrations directory; touch
a *different* module in the same library so GHC runs but has no reason to recompile the
embed module; build again and observe success — the stale embed shipped. The key mechanics:
the new file is not in any `addDependentFile` set, so GHC's recompilation check finds
`Internal/Definition.hs` up to date and never reruns the splice.

Phase B (post-fix): restore the pragma, repeat the identical sequence, and observe the
build now FAIL with `UnlistedSqlFiles ["0099-stale-embed-drill.sql"]` — the plugin forced
the splice to rerun the directory check.

Phase C (the documented residual): with the pragma in place and the unlisted file still
present, revert the touched module so *no* Haskell source differs from the last build, and
run the build again: cabal reports up to date without invoking GHC, and the failure does
not fire. This is the honest limit the comment states; it is covered by clean builds and by
Milestone 2's runtime directory check.

Clean up the drill file afterwards. Acceptance: pragma present, suite green, all three
phase transcripts recorded.

### Milestone 2 — the native lockfile (MIG-7)

Scope: decide-and-implement native manifest coverage. The decision (first Decision Log
entry) is the lockfile; this milestone implements it and updates the ownership guide's
enforcement statement.

Generate `keiro-migrations/migrations.native.lock` in the same two-space format as
`migrations.lock` (`<64-hex-sha256>␣␣<filename>`, one line per file, in manifest order),
covering all 20 files currently in `keiro-migrations/migrations/` — the exact generation
command is in Concrete Steps. Register it under `extra-source-files` in
`keiro-migrations/keiro-migrations.cabal` (next to the existing `migrations.lock` entry).

Add a spec to `keiro-migrations/test/Main.hs` (`describe "native checksum lockfile"`)
asserting four-way agreement between the lockfile, the manifest, the on-disk directory, and
the file bytes, at test runtime:

- Parse `keiro-migrations/migrations.native.lock` with the existing `parseLockfile` helper
  (locate it with the existing `findFile` pattern, candidates
  `keiro-migrations/migrations.native.lock` and `migrations.native.lock`).
- Read the manifest (the suite already does this in "tracks twenty native files in
  manifest order") and list the directory's `*.sql` files.
- Assert: the lockfile's filename list equals the manifest's entries exactly and in order;
  the sorted directory `*.sql` listing equals the sorted manifest entries (this is the
  runtime membership check that backstops Milestone 1's Phase C residual — an unlisted
  `0099-*.sql` on disk fails here even when no compile ever reran); and for every entry,
  `checksumText` of the on-disk bytes equals the recorded checksum.

The failure messages must name the offending file (missing from lockfile, extra on disk, or
checksum mismatch) so the developer knows whether to append a lockfile line or investigate
tampering.

Update `docs/user/migration-ownership.md` (the sections this plan owns). In the Framework
Components paragraph about the manifest, and in the Authoring section, state the
enforcement points honestly and completely: (1) compile time — the manifest embedder
validates order, membership, and payloads, with the RecompilePlugin caveat that a build in
which GHC never runs cannot revalidate; (2) review/test time — `migrations.native.lock`
pins every native file's SHA-256 and its membership, enforced by the default suite on every
`just verify`; (3) deploy time — the `pgmigrate` ledger keys applied history by checksum
and fails closed on any divergence. Also state the authoring rule the lockfile implies:
every new migration lands as a three-file diff (SQL file, manifest line, native-lock line),
and the review checklist is exactly that the three agree. Mention that `migrations.lock`
(no `native`) is frozen codd-cutover evidence and must never gain entries.

Acceptance: suite green; editing one byte of any native SQL file makes the suite fail
naming that file; adding an unlisted `.sql` to the directory makes it fail naming that
file; both revert cleanly.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

Milestone 1, Phase A (pre-fix — run before adding the pragma, or with it commented out):

```bash
cabal build keiro-migrations
printf -- '-- drill: intentionally unlisted\nSELECT 1;\n' \
  > keiro-migrations/migrations/0099-stale-embed-drill.sql
printf '\n-- recompile poke\n' >> keiro-migrations/src/Keiro/Migrations.hs
cabal build keiro-migrations && echo "BUILD OK (stale embed shipped)"
```

Expected: GHC recompiles `Keiro.Migrations` only, and the final line prints — the
unlisted file went unnoticed:

```text
[2 of 4] Compiling Keiro.Migrations
BUILD OK (stale embed shipped)
```

Milestone 1, Phase B (post-fix — pragma in place; poke the module again so GHC runs):

```bash
printf '\n-- recompile poke 2\n' >> keiro-migrations/src/Keiro/Migrations.hs
cabal build keiro-migrations
```

Expected failure:

```text
Keiro/Migrations/Internal/Definition.hs: error: [GHC-87897]
    invalid pg-migrate manifest: UnlistedSqlFiles ["0099-stale-embed-drill.sql"]
```

Milestone 1, Phase C (the residual): revert the pokes so no Haskell source differs, keep
the drill file, and build:

```bash
git checkout -- keiro-migrations/src/Keiro/Migrations.hs
cabal build keiro-migrations && echo "up to date; GHC never ran; plugin could not fire"
```

Cleanup:

```bash
rm keiro-migrations/migrations/0099-stale-embed-drill.sql
git status --short   # only intended edits remain
cabal test keiro-migrations-test
```

Milestone 2, lockfile generation (order taken from the manifest so review diffs stay
stable):

```bash
cd keiro-migrations
while IFS= read -r f; do shasum -a 256 "migrations/$f" \
  | awk -v f="$f" '{print $1 "  " f}'; done < migrations/manifest \
  > migrations.native.lock
cd ..
wc -l keiro-migrations/migrations.native.lock
```

Expected: `20 keiro-migrations/migrations.native.lock`, entries from
`0001-keiro-bootstrap.sql` through
`0020-keiro-workflow-children-failure-reason.sql`.

Milestone 2, verification loop:

```bash
cabal test keiro-migrations-test
# tamper drill: flip one byte, expect a named failure, then restore
printf -- '-- tamper\n' >> keiro-migrations/migrations/0017-schema-management-comment.sql
cabal test keiro-migrations-test; echo "exit=$?"
git checkout -- keiro-migrations/migrations/0017-schema-management-comment.sql
# membership drill: unlisted file, expect a named failure, then remove
touch keiro-migrations/migrations/0099-membership-drill.sql
cabal test keiro-migrations-test; echo "exit=$?"
rm keiro-migrations/migrations/0099-membership-drill.sql
cabal test keiro-migrations-test
just verify
```

Expected tamper-drill excerpt:

```text
native checksum lockfile
  pins every native migration byte-for-byte [✘]
    migrations.native.lock checksum mismatch for 0017-schema-management-comment.sql
exit=1
```

(Note the tamper drill may fail at *build* time instead, with a
`MigrationChecksumMismatch`-free but embed-refreshed binary and a failing byte-parity
expectation — either failure mode is acceptance; record which fired.)


## Validation and Acceptance

1. `keiro-migrations/src/Keiro/Migrations/Internal/Definition.hs` carries the
   `RecompilePlugin` pragma with the explanatory comment; `cabal build keiro-migrations`
   and `cabal test keiro-migrations-test` are green from the repository root.
2. The three reproduction transcripts (hazard, catch, residual) are recorded in Surprises
   & Discoveries with real output.
3. `keiro-migrations/migrations.native.lock` exists with 20 entries matching
   `migrations/manifest` order; it is listed in `extra-source-files`.
4. The tamper drill (append one comment line to any native SQL file) fails the suite
   naming that file; restoring the file restores green.
5. The membership drill (an unlisted `.sql` in `migrations/`) fails the suite naming that
   file with no compile in between — proving the runtime backstop for the pragma's
   residual gap.
6. `docs/user/migration-ownership.md` states the three enforcement points (compile, test,
   deploy) and the three-file authoring diff rule; `migrations.lock` is documented as
   frozen legacy evidence.
7. `just verify` passes end to end.


## Idempotence and Recovery

All steps are re-runnable. The drills create and delete scratch files under
`keiro-migrations/migrations/` and append revertable lines to tracked files; `git checkout
-- <path>` and `rm` of the drill files restore any intermediate state. Lockfile generation
is deterministic — rerunning the generation command on unchanged migrations produces a
byte-identical file (verify with `git diff --exit-code
keiro-migrations/migrations.native.lock` after a second run). If the Phase A hazard cannot
be reproduced (for example a cabal version that tracks directory mtimes more aggressively),
that is itself a finding: record the observed behavior in Surprises & Discoveries, keep the
pragma (it is documented upstream policy for GHC 9.12 and harmless at worst), and proceed —
the plan's acceptance rests on Phases B and C plus the lockfile, not on Phase A failing in
one particular way. Nothing in this plan touches a persistent database.


## Interfaces and Dependencies

No new package dependencies. `pg-migrate-embed ^>=1.1.0.0` (already a library dependency)
provides both `embedMigrationManifest` and the `Database.PostgreSQL.Migrate.Embed.RecompilePlugin`
module the pragma loads. The suite reuses its existing helpers in
`keiro-migrations/test/Main.hs`: `parseLockfile :: Text -> [(FilePath, Text)]`,
`checksumText :: ByteString -> Text` (SHA-256 via pg-migrate's `migrationFingerprint`),
`findFile`/`findMigrationsDirectory`. No library API changes at all in this plan; the only
compiled-code change is the pragma. The new artifact contract: every file listed in
`keiro-migrations/migrations/manifest` has exactly one line in
`keiro-migrations/migrations.native.lock` of the form `<sha256-hex>␣␣<filename>`, and the
suite enforces lockfile = manifest = directory = bytes on every run. Sibling-plan touch
points: `test/Main.hs` gains independent `describe` groups here and in
`docs/plans/122-restore-live-schema-verification-body-lint-and-the-startup-handshake-under-pg-migrate.md`
(merge-order coordination only), and `docs/user/migration-ownership.md` is owned by this
plan while `docs/user/migrations.md` and `docs/user/upgrading-to-the-keiro-schema.md`
belong to the siblings.


Revision note (2026-07-23): Inherited the MasterPlan intention and revised the native
coverage target from the plan-authoring count of 18 migrations to the current 20-file
manifest after EP-1 established that migrations 0019 and 0020 had landed.
