---
name: release
description: Release the keiro Hackage packages (keiro-core, keiro, keiro-pgmq, keiro-migrations, keiro-dsl, keiro-ops) together under one shared PVP version, in dependency order.
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
- Because the packages are interdependent and share a version, all internal
  version bounds (`keiro`, `keiro-pgmq`, and `keiro-dsl` depending on
  `keiro-core`, plus `keiro-ops` depending on `keiro`, `keiro-pgmq`, and
  `keiro-migrations`) must be bumped in lockstep with the release version.

## Packages (in dependency order)

Publish in **this order** — dependencies first. `keiro`, `keiro-pgmq`, **and
`keiro-dsl`** all depend on `keiro-core` at the library level.
`keiro-migrations` has no internal library dependency. `keiro-ops` depends on
`keiro`, `keiro-pgmq`, and `keiro-migrations`, so it is always last.

1. **keiro-core** (`keiro-core/`) — core stream/codec/event contracts. No internal deps.
2. **keiro** (`keiro/`) — the event-sourcing & workflow framework. Depends on `keiro-core`.
3. **keiro-pgmq** (`keiro-pgmq/`) — PGMQ job-queue integration. Depends on `keiro-core`.
4. **keiro-migrations** (`keiro-migrations/`) — schema migrations + `keiro-migrate` exe. No internal library deps.
5. **keiro-dsl** (`keiro-dsl/`) — typed `.keiro` spec toolchain (library + `keiro-dsl` exe). Depends on `keiro-core`.
6. **keiro-ops** (`keiro-ops/`) — embeddable operational command tree + `keiro-ops` exe. Depends on `keiro`, `keiro-pgmq`, and `keiro-migrations`.

Do not assume the internal dependency graph from this list — re-derive every
internal-package occurrence from all six manifests each release with the scan
in step 3. The 0.7.0.0 release found the
skill's previous claim that "`keiro-dsl`'s library is standalone" to be false,
and that its `keiro-core` dependency had shipped in 0.6.0.0 with **no version
bound at all**.

The following packages are **NOT released** to Hackage:

- **keiro-test-support** (`keiro-test-support/`) — internal: shared PostgreSQL
  test fixtures, consumed only by the packages' test suites.
- **jitsurei** (`jitsurei/`) — internal: guide-backed worked examples, not a
  reusable library.

> **⚠️ Hackage prerequisite — verify before uploading, do not trust this
> paragraph.** Hackage cannot resolve git dependencies, so uploading a package
> whose deps are git pins produces something that will not build for consumers.
> **Re-derive the state every release** — the upstreams are actively being
> published and this text goes stale fast.
>
> Check it mechanically rather than from memory:
>
> ```bash
> grep -A4 source-repository-package cabal.project      # what is still a git pin
> # then, for each non-boot library dep of each published package:
> curl -s https://hackage.haskell.org/package/<dep>/preferred -H 'Accept: application/json'
> ```
>
> A `404 Package not found` means it is unpublished. Confirm the versions
> returned actually satisfy the declared bounds.
>
> **State as of the 0.7.0.0 release (2026-08-01):** `cabal.project` is down to a
> single git pin — `codd` v0.1.8. `codd` and `codd-extras` are **not** on
> Hackage, but in `keiro-migrations` they sit entirely behind
> `flag legacy-codd-tools` (`default: False`, `manual: True`): the library deps
> are inside `if flag(legacy-codd-tools)`, and `keiro-write-expected-schema` /
> `keiro-migrations-legacy-test` are `buildable: False` when it is off. The
> default build plan never needs them, so this is **not** a blocker. Everything
> else — `keiki`, `keiki-codec-json`, `kiroku-store`, `kiroku-store-migrations`,
> the shibuya and pgmq stacks, `pg-migrate*`, `mmzk-typeid`, `ephemeral-pg` — is
> on Hackage.
>
> If an upstream is genuinely unpublished and reachable from the default build
> plan, stop and tell the user — do not upload a broken package.

> **Known, accepted gap.** `keiro`'s and `keiro-pgmq`'s test-suites depend on
> `keiro-test-support`, which is deliberately never published. Hackage's build
> bot therefore cannot build those suites. This is pre-existing and outside the
> default consumer build plan — note it, but do not treat it as a blocker or try
> to "fix" it during a release.

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
- Otherwise infer it from the commits and the `## [Unreleased]` sections of the
  **root** `CHANGELOG.md` *and* every per-package `CHANGELOG.md`:
  - breaking / remove / rename / changed type or semantics → **major**
  - add / new / feature / new export or module → **minor**
  - fix / docs / refactor / internal / performance → **patch**
  - When in doubt, pick the highest level any change implies.
  - A dependency **upper-bound bump** on a load-bearing upstream (e.g.
    `keiki >=0.6` → `>=0.7`) is a **breaking** change for consumers even when
    this repo's own API is untouched, because it changes what a consumer can
    solve for and may change verification results. Treat it as major.
  - `keiro-dsl` language-version work is almost always major: new
    `DiagnosticCode` constructors break exhaustive matches even though they are
    "append-only".
- Increment the shared version:
  - **major**: increment `B`, reset `C` and `D` to `0` (`0.1.0.0` → `0.2.0.0`)
  - **minor**: increment `C`, reset `D` to `0` (`0.1.0.0` → `0.1.1.0`)
  - **patch**: increment `D` (`0.1.0.0` → `0.1.0.1`)
- **Present the proposed bump to the user and get confirmation before making any edits.**

### 3. Update versions, internal bounds, and changelogs

#### Version bump
Set the new `version:` in every published package's cabal file:
`keiro-core/keiro-core.cabal`, `keiro/keiro.cabal`, `keiro-pgmq/keiro-pgmq.cabal`,
`keiro-migrations/keiro-migrations.cabal`, `keiro-dsl/keiro-dsl.cabal`,
`keiro-ops/keiro-ops.cabal`.

Leave `keiro-test-support` and `jitsurei` as they are unless you deliberately
choose to bump them for consistency (they are not published).

#### Internal dependency bounds
Find every internal dependency first — do not work from a remembered list:

```bash
rg -n -g '*.cabal' 'keiro-core|keiro-migrations|keiro-pgmq|(^|[ ,])keiro([ ,]|$)' \
  keiro-core keiro keiro-pgmq keiro-migrations keiro-dsl keiro-ops
```

`keiro`, `keiro-pgmq`, and `keiro-dsl` all depend on `keiro-core`. Set each to a
PVP-compatible bound matching the new version: `keiro-core ^>=A.B.C.D`. Update
**every** stanza that carries an existing bound (library, test-suite, benchmark).
Set `keiro-ops`'s bounded dependencies on `keiro`, `keiro-pgmq`, and
`keiro-migrations` to that same shared version.

If a stanza lists `keiro-core` with **no** bound, that is a defect, not a style
choice — an unbounded internal dep lets a consumer solve a new major `keiro-core`
against an old dependent. Add the bound and call it out in the changelog as a
breaking change. Leave the unbounded internal deps in `keiro-dsl`'s conformance
test-suites alone, though: those stanzas are unbounded for *all* internal deps
(`keiro`, `keiro-pgmq`, `keiro-dsl` too), so bounding only `keiro-core` there
would be arbitrary churn.

#### Re-exports
If `keiro-core` gained a **public module this cycle that generated code
imports**, check whether `keiro` needs to re-export it:

```bash
grep -rn 'import Keiro\.' keiro-dsl/src/Keiro/Dsl/Scaffold.hs keiro-dsl/src/Keiro/Dsl/Harness.hs
```

Every `keiro-core` module that scaffolded output imports must appear in
`keiro`'s `reexported-modules`, because consumers of generated services are
expected to need only a single direct `keiro` dependency. The in-repo
conformance suites **cannot** catch a miss here — they depend on `keiro-core`
directly. 0.7.0.0 shipped `Keiro.Codec.IdDomain` and needed exactly this fix.

#### Changelogs
All six published packages have a `CHANGELOG.md`, plus a root
`CHANGELOG.md` summarizing the release across packages (it feeds the GitHub
release notes in step 7). All follow
[Keep a Changelog](https://keepachangelog.com/) + PVP with dates in
`YYYY-MM-DD`.

- In each, leave `## [Unreleased]` in place and insert a new
  `## <version> — <YYYY-MM-DD>` heading directly below it, above the previous
  entries. Existing `[Unreleased]` content becomes that section's body.
- If a package genuinely has no user-facing change, a short "No changes this
  release" note is fine. `keiro-pgmq` and `keiro-migrations` are usually this.
- Group entries by **Breaking Changes** (major only) / **New Features** /
  **Bug Fixes** / **Other Changes**; include only non-empty groups. Use exactly
  these headings — Keep a Changelog's bare `### Fixed` has crept in before and
  should be normalized to `### Bug Fixes`.

**Reconcile the root changelog against the per-package ones — do not trust it.**
The root `[Unreleased]` section is written incrementally during the cycle and
reliably lags the last few commits. At 0.7.0.0 it was missing an entire
initiative (language v3 / enforced TypeID ID-domain, nominal ownership
centralization, semantic-contract threading) that `keiro-dsl/CHANGELOG.md`
already recorded in full. Diff it before trusting it:

```bash
git log --oneline <anchor-tag>..HEAD
git diff <anchor-tag>..HEAD -- CHANGELOG.md
```

Every commit since the anchor should be represented somewhere. Note that an
in-cycle `fix:` commit repairing work introduced *in the same cycle* is not
user-facing and correctly gets **no** entry — only fixes to already-released
behavior belong under Bug Fixes.

#### Blueprint migration edge

`blueprints/keiro-upgrade/` publishes Keiro's upgrade knowledge as one
agent-guided edge per version window, consumed by
`seihou agent migrate keiro-upgrade`. **Decide, every release, whether this one
needs an edge — and record the decision either way.**

An edge is needed when a consumer must change source, fixtures, or database
state to cross this release: a changed or removed export, a new constructor on
an exported sum type, a renamed configuration key, a migration whose recorded
checksum moves, or a regeneration this release forces on DSL consumers. A
release that is purely additive and source-compatible needs none — undeclared
gaps between edges are legal and mean exactly "no agent intervention was
required here."

To add one:

1. Write `blueprints/keiro-upgrade/migrations/<from>-to-<to>.md`. Name the exact
   APIs that changed and what they became, state the edge's precondition, say
   which of *this project's* validation commands prove it worked, and call out
   what the agent must not do. Keep it to what a consumer must change — the
   changelog already explains what happened.
2. Append a `S.BlueprintMigration::{ from, to, prompt }` entry to
   `blueprint.dhall`. `from` is the **last release before the break**, not the
   earliest release the edge could apply from: Seihou selects an edge whose
   `from` is at or after the consumer's cursor, so a lower `from` is skipped by
   anyone already past it.
3. **If this release absorbs an upstream breaking change, declare it in
   `entails`** rather than copying that library's guidance here. Name the exact
   upstream edge, matched on both `from` and `to`; Seihou will not window-plan
   inside the entailed blueprint. The upstream blueprint must declare that
   edge or the consumer's run fails outright, so add the upstream edge first,
   in the upstream repository. Today that means `kiroku-upgrade`, in the kiroku
   repository.

   **Declaring it upstream is not enough — it must be *pushed*.** Consumers
   install blueprints from git, so an upstream edge that exists only in a local
   checkout is unreachable, and every consumer's run refuses. A local
   `seihou agent --debug migrate` preview will happily pass against that local
   checkout and tell you nothing, because it resolves the same working tree you
   authored. Verify against the remote before tagging:

   ```bash
   git -C <upstream-repo> fetch -q origin
   git -C <upstream-repo> branch -r --contains <blueprint-commit>
   ```

   Empty output means unpushed — stop and get it pushed. This was caught by
   accident at 0.13.0.0, one step before an irreversible Hackage upload.
4. Bump the blueprint's own `version` and the matching entry in
   `seihou-registry.dhall`, and update the edge table in
   `blueprints/keiro-upgrade/README.md` and the cohort map in
   `blueprints/keiro-upgrade/files/keiro-cohort-versions.md`.
5. Validate and preview a real chain — validation alone cannot check an
   entailment, because whether the named blueprint declares the named edge is a
   filesystem question:

   ```bash
   seihou validate-blueprint blueprints/keiro-upgrade
   seihou agent --debug migrate keiro-upgrade --from <prev> --to <next>
   ```

   The preview must show every expected step, in order, each labelled with the
   blueprint that owns it. Contacting no provider and writing nothing, it is
   safe to run as often as you like.

This step exists because the alternative has already failed once:
`migrate-keiro-stack` in `agent-seihou` describes "the current cohort" rather
than a sequence of edges, nothing forced it forward at release time, and it
still pins `kiroku-store 0.3.1.0`. An append-only edge list cannot rot that way
— but only if every release adds its edge.

**Show the user every change — version bumps, bound updates, changelog edits,
and the blueprint edge (or the reasoning for not adding one) — for review before
committing.**

### 4. Verify (mandatory gate)

Run the project's canonical release gate. The test suites need PostgreSQL, which
`just verify` provisions via process-compose:

```
nix fmt           # treefmt: fourmolu + cabal-fmt + nixpkgs-fmt
just corpus-regen # restamp generated conformance provenance with the new version
just verify       # process-compose-check + jitsurei + cabal build all + tests + diagrams --check + keiro-migrations-test
nix flake check   # treefmt + pre-commit hooks gate
```

- **`just corpus-regen` is mandatory on every version bump, not optional.** Every
  generated conformance artifact carries a `@generated by keiro-dsl <version>`
  provenance header, so bumping `keiro-dsl` invalidates all ~433 of them.
  `just verify`'s `conformance-corpus-policy` runs
  `keiro-dsl-corpus-regen -- check` and **will fail** until you regenerate.
  Run it after `nix fmt` and before `just verify`, then confirm the diff is
  provenance-only before trusting it:

  ```bash
  git diff -U0 -- 'keiro-dsl/test/**' | grep -E '^[+-]' | grep -v '^[+-][+-]' \
    | grep -v '@generated by keiro-dsl'
  ```

  That must print nothing. Any other hunk means the bump changed real generated
  output — stop and surface it, because it is a language-contract change the
  changelog and the blueprint edge both need to describe.
- **On a version bump, the release commit must come *before* the final `just
  verify`.** `conformance-corpus-policy` runs `keiro-dsl-corpus-regen -- check`,
  which refuses to run at all against uncommitted corpus paths — it exits 1 with
  "Commit or stash the listed paths" rather than comparing content. So the
  regenerated corpus fails the gate precisely because it is still unstaged. This
  inverts step 5's ordering for any release that restamps provenance: regenerate,
  make the commit, then run `just verify` and `nix flake check` against the clean
  tree, and create the tags only once both pass. Amend the commit if they do not.
  Do not reach for `--allow-dirty`; it is for local iteration and defeats the check.
- Run `nix fmt` first so formatting changes are in the tree before the checks.
  Expect it to touch `.cabal` files you edited: `cabal-fmt` realigns the
  `build-depends` version column whenever a bound's width changes (adding
  `^>=A.B.C.D` to a previously unbounded dep reflows the whole stanza). This is
  correct — keep it.
- Newly created files (e.g. a new `CHANGELOG.md`) must be `git add`-ed before
  `nix flake check`, since Nix evaluates the git tree.
- `just verify` runs the full build and every suite; it routinely exceeds 10
  minutes. Run it in the background rather than letting a foreground timeout
  kill it, and check the exit code — not just the tail of the log. Beware
  `just verify > log 2>&1; echo $?`: the trailing `echo` succeeds, so the
  compound command's status is `0` and a failed gate reads as a pass. Put the
  status *inside* the log (`echo "EXIT=$?" | tee -a log`) and grep for it.
- **A release that absorbs an upstream migration payload change breaks the
  persistent `jitsurei` database.** `just verify` depends on `jitsurei-migrate`,
  which runs `keiro-migrate up` against the long-lived local `jitsurei`
  database. When the release changes a recorded checksum, that database fails
  with `MigrationChecksumMismatch` exactly as a consumer's would — the gate
  failure is the release working as documented, not a defect. Apply the release's
  own documented ledger fixup to it rather than dropping the database; doing so
  rehearses the guidance being shipped and proves it before consumers run it.
  At 0.13.0.0 that was `kiroku-store-migrations`'
  `ledger-fixups/2026-08-16-rebaseline-0010-checksum.sql`.
- Unrelated untracked files (e.g. planning docs for the *next* initiative) are
  fine to leave in the tree; Nix ignores them and they stay out of the release
  commit. Mention them to the user rather than staging them.
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
  for pkg in keiro-core keiro keiro-pgmq keiro-migrations keiro-dsl keiro-ops; do
    git tag -a "$pkg-<version>" -m "$pkg <version>"
  done
  ```

- Push the commit and tags: `git push && git push --tags`.
- Do this **only after** the user has approved the changes in step 3.

### 6. Publish to Hackage (in dependency order)

For **each** publishable package, in the order
`keiro-core → keiro → keiro-pgmq → keiro-migrations → keiro-dsl → keiro-ops`:

1. Re-confirm the package's dependencies are all on Hackage (see the
   prerequisite warning above). If a dependency reachable from the **default**
   build plan is still a git pin, **stop**. A git-pinned dep behind a
   default-off `manual` flag is fine.
2. `cabal check` — run it from `<pkg-dir>`; it is the only step that needs to be.
   Fix any packaging warnings before uploading.
3. Re-run the package's test suite if it has one (already covered by `just
   verify`, but a final per-package check is cheap): `keiro` → `cabal test
   keiro-test`, `keiro-pgmq` → `cabal test keiro-pgmq-test`, `keiro-migrations`
   → `cabal test keiro-migrations-test`, `keiro-dsl` → `cabal test
   keiro-dsl-test`, `keiro-ops` → `cabal test keiro-ops-test`. `keiro-core`
   has no dedicated suite — skip.
4. `cabal sdist` from `<pkg-dir>`, then upload **from the repo root**.
   Note the path: the tarball lands in the *workspace* `dist-newstyle/`, not in
   the package directory —

   ```bash
   cabal upload --publish dist-newstyle/sdist/<pkg>-<version>.tar.gz
   ```

5. Build and upload docs **from the repo root**, naming the package explicitly
   so haddock does not build the whole workspace:

   ```bash
   cabal haddock --haddock-for-hackage --haddock-hyperlink-source \
     --haddock-quickjump <pkg>
   cabal upload --publish --documentation dist-newstyle/<pkg>-<version>-docs.tar.gz
   ```

6. Report the Hackage URL:
   `https://hackage.haskell.org/package/<pkg>-<version>`.

After all six, confirm each is actually live rather than trusting the upload
output — both the package page and its docs:

```bash
for p in keiro-core keiro keiro-pgmq keiro-migrations keiro-dsl keiro-ops; do
  echo "$p $(curl -s -o /dev/null -w '%{http_code}' https://hackage.haskell.org/package/$p-<version>)" \
       "$(curl -s -o /dev/null -w '%{http_code}' https://hackage.haskell.org/package/$p-<version>/docs/)"
done
```

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
| keiro-ops | X.Y.Z.W | https://hackage.haskell.org/package/keiro-ops-X.Y.Z.W |

### 7. Create the GitHub release (required)

After all Hackage uploads succeed, create a GitHub release. Tags are
per-package, so anchor the release on the flagship tag `keiro-<version>` and
title it with the shared version:

Build the notes in a scratch file and pass `--notes-file`. Do **not** try to
inline the body with `--notes "$(cat <<'EOF' ... EOF)"` — the release notes are
themselves Markdown containing fenced blocks and tables, and nesting heredocs
inside command substitution is needlessly fragile.

Extract this version's section from the root `CHANGELOG.md` mechanically rather
than retyping it:

```bash
awk '/^## <version>/{f=1;next} /^## <prev-version>/{exit} f' CHANGELOG.md > "$S/relnotes-body.md"
# prepend the Packages table, then:
gh release create keiro-<version> --title "keiro <version>" --notes-file "$S/relnotes.md"
```

- Include the per-package tag names in the Packages table alongside the Hackage
  links — the release is anchored on `keiro-<version>` only, so the other five
  tags are otherwise undiscoverable from the release page.
- Verify it landed and is not a draft:
  `gh release view keiro-<version> --json tagName,isDraft,url`
- Report the GitHub release URL when done.

## Important

- Always ask the user to **confirm the version bump and changelogs before
  committing**.
- Always publish in dependency order: **keiro-core → keiro → keiro-pgmq →
  keiro-migrations → keiro-dsl → keiro-ops**.
- Never skip the gates: `nix fmt`, `just verify`, `cabal check`, `nix flake
  check`.
- **Stop on any failure** — a failed gate, `cabal check`, or upload. Do not
  continue publishing dependents after an upstream upload fails.
- Do **not** upload a package whose default-build-plan dependencies are not yet
  on Hackage. Verify with `curl` against Hackage each release; stop and report
  otherwise. Do not rely on this file's snapshot of which upstreams are
  published — it goes stale between releases.
- Re-derive the internal dependency graph and the `reexported-modules` list from
  the cabal files each release rather than trusting the summaries here.
- The commit, tags, and uploads happen **only after** the user approves the
  staged changes. Publishing to Hackage is irreversible.
- When a step reveals a genuine defect in the release as staged (an unbounded
  internal dep, a public module generated code imports but `keiro` does not
  re-export), surface it to the user with the evidence and let them decide —
  do not silently widen the release, and do not quietly ship the defect.
