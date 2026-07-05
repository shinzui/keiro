---
name: release
description: Release the keiro Hackage packages (keiro-core, keiro, keiro-pgmq, keiro-migrations, keiro-dsl) together under one shared PVP version, in dependency order.
argument-hint: "[major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# keiro Release Skill

Release the publishable **keiro** packages to [Hackage](https://hackage.haskell.org/)
following the Haskell [PVP](https://pvp.haskell.org/) (`A.B.C.D`). This is a
Cabal multi-package workspace (GHC 9.12 / GHC2024, Nix flake, `just`
task runner). All published packages share **one version number** and are
released together, but each gets its **own annotated git tag**.

## Versioning strategy

- All published packages carry the **same version** and are released as a set.
- Version format is PVP `A.B.C.D`:
  - `A.B` — **major**: breaking API changes (removed/renamed exports, changed
    types or semantics).
  - `C` — **minor**: backwards-compatible API additions (new exports, modules,
    instances).
  - `D` — **patch**: bug fixes, docs, internal-only or performance changes.
- Because the packages are interdependent and share a version, the internal
  version bounds (`keiro`/`keiro-pgmq` depending on `keiro-core`) must be bumped
  in lockstep with the release version.

## Packages (in dependency order)

Publish in **this order** — dependencies first. `keiro` and `keiro-pgmq` depend
on `keiro-core` at the library level; `keiro-migrations` and `keiro-dsl` have no
internal library dependencies but are released with the set.

1. **keiro-core** (`keiro-core/`) — core stream/codec/event contracts. No internal deps.
2. **keiro** (`keiro/`) — the event-sourcing & workflow framework. Depends on `keiro-core`.
3. **keiro-pgmq** (`keiro-pgmq/`) — PGMQ job-queue integration. Depends on `keiro-core`.
4. **keiro-migrations** (`keiro-migrations/`) — schema migrations + `keiro-migrate` exe. No internal library deps.
5. **keiro-dsl** (`keiro-dsl/`) — typed `.keiro` spec toolchain (library + `keiro-dsl` exe). Library is standalone.

The following packages are **NOT released** to Hackage:

- **keiro-test-support** (`keiro-test-support/`) — internal: shared PostgreSQL
  test fixtures, consumed only by the packages' test suites.
- **jitsurei** (`jitsurei/`) — internal: guide-backed worked examples, not a
  reusable library. (Note: `site-dist/jitsurei/` is generated website output —
  ignore it; it is not in `cabal.project`.)

> **⚠️ Hackage prerequisite — read before uploading.** Several publishable
> packages currently depend on **git-pinned upstreams that are not yet on
> Hackage**, declared as `source-repository-package` in `cabal.project`:
> `keiro-core` → `keiki`, `kiroku-store`; `keiro-pgmq` → the shibuya pgmq
> adapter stack; `keiro-migrations` → `kiroku-store-migrations`, `codd`.
> Hackage cannot resolve git dependencies, so `cabal upload` of a package with
> unpublished deps produces a package that will not build for consumers. Before
> the real upload, confirm every transitive dependency of the package being
> published is available on Hackage with compatible bounds. `keiro-dsl`'s
> **library** has no such git deps and is the most self-contained. If the
> upstreams are not yet published, stop and tell the user — do not upload a
> broken package.

## Arguments

`$ARGUMENTS` is optional:

- `major`, `minor`, or `patch` — forces the bump level.
- If omitted, infer the bump level from the changes (see step 2).

## Steps

### 1. Determine what changed since the last release

- Read the current shared version from any package's `.cabal` (they all match —
  e.g. `keiro/keiro.cabal`).
- Find the last release point. Tags are **per-package** (`<pkg>-<version>`), so
  list them and take the highest previous shared version:
  `git tag --list 'keiro-*' 'keiro-core-*'`. Use the flagship tag
  `keiro-<prev-version>` as the diff anchor (all packages share the version, so
  one anchor is enough). If there are **no tags**, this is the first release —
  say so and diff from the repository root.
- Run `git log --oneline <anchor-tag>..HEAD` (or the full log for a first
  release) to list commits since the last release.
- If there are no commits since the last tag, tell the user there is nothing to
  release and stop.

Present a summary: current version, last release anchor (or "none — first
release"), commit count since then, and which package directories changed.

### 2. Determine the next version using PVP

- If `$ARGUMENTS` is `major`, `minor`, or `patch`, use that bump level.
- Otherwise infer it from the commits and the `## [Unreleased]` section of
  `keiro/CHANGELOG.md`:
  - breaking / remove / rename / changed type or semantics → **major**
  - add / new / feature / new export or module → **minor**
  - fix / docs / refactor / internal / performance → **patch**
  - When in doubt, pick the highest level any change implies. Note that the
    current `keiro/CHANGELOG.md` `Unreleased` section already flags a
    **Breaking API** change (validated event streams) — respect that.
- Increment the shared version:
  - **major**: increment `B`, reset `C` and `D` to `0` (`0.1.0.0` → `0.2.0.0`)
  - **minor**: increment `C`, reset `D` to `0` (`0.1.0.0` → `0.1.1.0`)
  - **patch**: increment `D` (`0.1.0.0` → `0.1.0.1`)
- **Present the proposed bump to the user and get confirmation before making any edits.**

### 3. Update versions, internal bounds, and changelogs

#### Version bump
Set the new `version:` in every published package's cabal file:
`keiro-core/keiro-core.cabal`, `keiro/keiro.cabal`, `keiro-pgmq/keiro-pgmq.cabal`,
`keiro-migrations/keiro-migrations.cabal`, `keiro-dsl/keiro-dsl.cabal`.

Leave `keiro-test-support` and `jitsurei` as they are unless you deliberately
choose to bump them for consistency (they are not published).

#### Internal dependency bounds
`keiro` and `keiro-pgmq` depend on `keiro-core` (currently `keiro-core >=0.1`).
Tighten these to a PVP-compatible bound matching the new version:
`keiro-core ^>=A.B.C.D`. Update **every** section that lists `keiro-core`
(library and test-suite stanzas). `keiro-dsl` and `keiro-migrations` have no
internal library dependency to bump.

#### Changelogs
- `keiro/CHANGELOG.md` exists and follows
  [Keep a Changelog](https://keepachangelog.com/) + PVP with dates in
  `YYYY-MM-DD`. Move the `## [Unreleased]` content into a new
  `## <version> — <YYYY-MM-DD>` section above the previous entries.
- For the other published packages (`keiro-core`, `keiro-pgmq`,
  `keiro-migrations`, `keiro-dsl`) that lack a `CHANGELOG.md`, create one when
  they have notable changes this cycle — same header + format, with a section
  for the new version. If a package genuinely has no user-facing change, a
  short "No changes this release" note is fine.
- Maintain a **root `CHANGELOG.md`** summarizing the release across packages
  (create it if missing) — it feeds the GitHub release notes in step 7.
- Group entries by **Breaking Changes** (major only) / **New Features** /
  **Bug Fixes** / **Other Changes**; include only non-empty groups.

**Show the user every change — version bumps, bound updates, changelog edits —
for review before committing.**

### 4. Verify (mandatory gate)

Run the project's canonical release gate. The test suites need PostgreSQL, which
`just verify` provisions via process-compose:

```
nix fmt          # treefmt: fourmolu + cabal-fmt + nixpkgs-fmt
just verify      # process-compose-check + jitsurei + cabal build all + tests + diagrams --check + keiro-migrations-test
nix flake check  # treefmt + pre-commit hooks gate
```

- Run `nix fmt` first so formatting changes are in the tree before the checks.
- Newly created files (e.g. a new `CHANGELOG.md`) must be `git add`-ed before
  `nix flake check`, since Nix evaluates the git tree.
- If **any** gate fails, fix it before proceeding — do not continue on a failure.

### 5. Commit, tag, and push

- Stage all modified `.cabal` and `CHANGELOG.md` files (and any files `nix fmt`
  touched).
- Create a single commit with a Conventional Commits message:
  `chore(release): <version>`. The body should summarize what's in the release
  and justify the chosen bump level.
- Create one **annotated per-package tag** at this commit, all at the shared
  version:

  ```bash
  for pkg in keiro-core keiro keiro-pgmq keiro-migrations keiro-dsl; do
    git tag -a "$pkg-<version>" -m "$pkg <version>"
  done
  ```

- Push the commit and tags: `git push && git push --tags`.
- Do this **only after** the user has approved the changes in step 3.

### 6. Publish to Hackage (in dependency order)

For **each** publishable package, in the order
`keiro-core → keiro → keiro-pgmq → keiro-migrations → keiro-dsl`:

1. Re-confirm the package's transitive dependencies are all on Hackage (see the
   prerequisite warning above). If any dependency is still a git pin, **stop**.
2. `cd <pkg-dir>`.
3. `cabal check` — fix any packaging warnings before uploading.
4. Re-run the package's test suite if it has one (already covered by `just
   verify`, but a final per-package check is cheap): `keiro` → `cabal test
   keiro-test`, `keiro-pgmq` → `cabal test keiro-pgmq-test`, `keiro-migrations`
   → `cabal test keiro-migrations-test`, `keiro-dsl` → `cabal test
   keiro-dsl-test`. `keiro-core` has no dedicated suite — skip.
5. `cabal sdist`, then `cabal upload --publish <tarball-path>`.
6. `cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump`,
   then `cabal upload --publish --documentation <docs-tarball-path>`.
7. Report the Hackage URL:
   `https://hackage.haskell.org/package/<pkg>-<version>`.

**If any upload fails, stop.** Never continue publishing a package whose
dependency failed to upload (e.g. do not publish `keiro` if `keiro-core` failed).

After all uploads, present a summary table:

| Package | Version | Hackage URL |
|---------|---------|-------------|
| keiro-core | X.Y.Z.W | https://hackage.haskell.org/package/keiro-core-X.Y.Z.W |
| keiro | X.Y.Z.W | https://hackage.haskell.org/package/keiro-X.Y.Z.W |
| keiro-pgmq | X.Y.Z.W | https://hackage.haskell.org/package/keiro-pgmq-X.Y.Z.W |
| keiro-migrations | X.Y.Z.W | https://hackage.haskell.org/package/keiro-migrations-X.Y.Z.W |
| keiro-dsl | X.Y.Z.W | https://hackage.haskell.org/package/keiro-dsl-X.Y.Z.W |

### 7. Create the GitHub release (required)

After all Hackage uploads succeed, create a GitHub release. Tags are
per-package, so anchor the release on the flagship tag `keiro-<version>` and
title it with the shared version:

```bash
gh release create keiro-<version> \
  --title "keiro <version>" \
  --notes "$(cat <<'EOF'
## Packages

| Package | Hackage |
|---------|---------|
| keiro-core | https://hackage.haskell.org/package/keiro-core-X.Y.Z.W |
| keiro | https://hackage.haskell.org/package/keiro-X.Y.Z.W |
| keiro-pgmq | https://hackage.haskell.org/package/keiro-pgmq-X.Y.Z.W |
| keiro-migrations | https://hackage.haskell.org/package/keiro-migrations-X.Y.Z.W |
| keiro-dsl | https://hackage.haskell.org/package/keiro-dsl-X.Y.Z.W |

## What's Changed

<paste this version's entries from the root CHANGELOG.md>
EOF
)"
```

- Optionally attach the other per-package tags in the notes for discoverability.
- Use the root `CHANGELOG.md` entries as the release-notes body.
- Report the GitHub release URL when done.

## Important

- Always ask the user to **confirm the version bump and changelogs before
  committing**.
- Always publish in dependency order: **keiro-core → keiro → keiro-pgmq →
  keiro-migrations → keiro-dsl**.
- Never skip the gates: `nix fmt`, `just verify`, `cabal check`, `nix flake
  check`.
- **Stop on any failure** — a failed gate, `cabal check`, or upload. Do not
  continue publishing dependents after an upstream upload fails.
- Do **not** upload a package whose transitive dependencies are not yet on
  Hackage (the git-pinned upstreams). Verify first; stop and report otherwise.
- The commit, tags, and uploads happen **only after** the user approves the
  staged changes. Publishing to Hackage is irreversible.
