---
name: release
description: Release the keiro Hackage packages (keiro-core, keiro, keiro-pgmq, keiro-migrations, keiro-dsl, keiro-ops, keiro-ops-http) together under one shared PVP version, in dependency order.
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
`keiro-migrations` has no internal library dependency. `keiro-test-support`
depends on `keiro-migrations`, so it follows it. `keiro-ops` depends on
`keiro`, `keiro-pgmq`, and `keiro-migrations`, so it is always last.

1. **keiro-core** (`keiro-core/`) — core stream/codec/event contracts. No internal deps.
2. **keiro** (`keiro/`) — the event-sourcing & workflow framework. Depends on `keiro-core`.
3. **keiro-pgmq** (`keiro-pgmq/`) — PGMQ job-queue integration. Depends on `keiro-core`.
4. **keiro-migrations** (`keiro-migrations/`) — schema migrations + `keiro-migrate` exe. No internal library deps.
5. **keiro-test-support** (`keiro-test-support/`) — shared suite-level PostgreSQL
   fixtures. Library depends on `keiro-migrations`.
6. **keiro-dsl** (`keiro-dsl/`) — typed `.keiro` spec toolchain (library + `keiro-dsl` exe). Depends on `keiro-core`.
7. **keiro-ops** (`keiro-ops/`) — embeddable operational command tree + `keiro-ops` exe. Depends on `keiro`, `keiro-pgmq`, and `keiro-migrations`.
8. **keiro-ops-http** (`keiro-ops-http/`) — HTTP transport and runner. Depends on `keiro-ops` and `keiro-migrations`, so upload it last.

Only **library** dependencies constrain upload order. `keiro`, `keiro-pgmq`,
`keiro-ops`, and `keiro-dsl` depend on `keiro-test-support` from their
test-suites and benchmark, not their libraries, so it is correct for it to be
uploaded after `keiro` and `keiro-pgmq` — a consumer's default build plan never
reaches it.

Do not assume the internal dependency graph from this list — re-derive every
internal-package occurrence from all eight manifests each release with the scan
in step 3. The 0.7.0.0 release found the
skill's previous claim that "`keiro-dsl`'s library is standalone" to be false,
and that its `keiro-core` dependency had shipped in 0.6.0.0 with **no version
bound at all**.

The following package is **NOT released** to Hackage:

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

> **Closed as of 0.14.0.0 — `keiro-test-support` is published.** It used to be
> repository-internal, which meant the `keiro`, `keiro-pgmq`, `keiro-ops`, and
> `keiro-dsl` test-suites could not be built from their Hackage tarballs at all.
> It is now a released package in the lockstep set and must be versioned,
> bounded, changelogged, tagged, and uploaded like any other. If you are reading
> an older release's notes describing this as an accepted gap, that text is
> stale.

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
`keiro-migrations/keiro-migrations.cabal`,
`keiro-test-support/keiro-test-support.cabal`, `keiro-dsl/keiro-dsl.cabal`,
`keiro-ops/keiro-ops.cabal`, and `keiro-ops-http/keiro-ops-http.cabal`.

Leave `jitsurei` as it is unless you deliberately choose to bump it for
consistency (it is not published).

#### Internal dependency bounds
Find every internal dependency first — do not work from a remembered list.
`keiro-ops` and `keiro-ops-http` need explicit alternatives: the whole-word
`keiro` alternative does not match their hyphenated names. Include jitsurei:

```bash
rg -n -g '*.cabal' \
  'keiro-core|keiro-migrations|keiro-pgmq|keiro-test-support|keiro-ops-http|keiro-ops|(^|[ ,])keiro([ ,]|$)' \
  keiro-core keiro keiro-pgmq keiro-migrations keiro-test-support keiro-dsl keiro-ops keiro-ops-http jitsurei
```

**Read the matches, do not blind-replace them.** A bulk
`s/\^>=<old>/\^>=<new>/` over the cabal files will also rewrite any *external*
dependency that happens to sit at the same version as the outgoing shared one.
At 0.14.0.0 that was `shibuya-pgmq-adapter`, which independently reached
`^>=0.14.0.0`; a blind replace bumped it to a version that does not exist and the
solver rejected the build. Diff each cabal file against `HEAD` before trusting
the edit — every changed line must be a version, an internal bound, or one-time
`cabal-gild` normalization.

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

Apply the same rule to every non-conformance stanza and every internal package,
including test suites and benchmarks. In particular,
`keiro-dsl-runtime-vocabulary-test` bounds both `keiro` and `shibuya-core`, and
`keiro-dsl-codec-bench` bounds `keiro`; keep those bounds aligned with the
released internal version and the independently verified `shibuya-core` release.

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
All eight published packages have a `CHANGELOG.md`, plus a root
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
   `seihou agent --debug migrate` preview tells you nothing about whether it is
   pushed. Verify against the remote before tagging:

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
5. Validate the working-tree blueprint:

   ```bash
   seihou validate-blueprint blueprints/keiro-upgrade
   ```

   The mandatory `release-preflight` in step 4 evaluates the current version
   window, verifies every upstream entailment is published, and previews the real
   chain using disposable project-local blueprint copies. It reads the current
   checkout rather than a stale installed Keiro blueprint. Do not copy over the
   user's installed artifacts or repeat the preview manually. A missing upstream
   edge must be authored and pushed in its owning repository before preflight
   passes. Source/fixture regeneration happens in preparation before that gate.

This step exists because the alternative has already failed once:
`migrate-keiro-stack` in `agent-seihou` describes "the current cohort" rather
than a sequence of edges, nothing forced it forward at release time, and it
still pins `kiroku-store 0.3.1.0`. An append-only edge list cannot rot that way
— but only if every release adds its edge.

**Show the user every change — version bumps, bound updates, changelog edits,
and the blueprint edge (or the reasoning for not adding one) — for review before
committing.**

### 4. Prepare once and verify the final candidate

All commands run from the repository root in the Nix development shell. Finish
step 3's versions, internal bounds, changelogs and blueprint edits **before**
preparation. Do not run a full old-version build first.

```bash
nix develop -c just release-prepare
```

This checks for dirty corpus paths before compiling, formats the tree, restamps
conformance provenance and refreshes both generated record inventories. It never
commits. If corpus paths have intentional edits, review and commit those edits
first; do not bypass the clean-corpus protection with `--allow-dirty`.

Review the generated diff. A version-only bump should change corpus provenance
only. Any other generated output change needs review as a language-contract
change, including appropriate changelog and upgrade guidance. Inventory changes
can include line anchors and newly discovered records; review them as well.

Stage newly created files and commit the prepared candidate as described in
step 5. The final gate needs committed corpus paths. Use append-only checkpoint
commits; do not amend a candidate that another process or user has already
pushed. Check `git status --short --branch` and remote ancestry before changing
history. Evidence-only commits may follow the tested candidate.

```bash
nix develop -c just release-gate
nix flake check
```

`release-gate` always runs preflight first: Z3, Mori terminology connectivity,
cheap policy/documentation checks, both generated inventories, eight `cabal
check` invocations, local blueprint validation and a dry-run dependency solve.
It previews the upgrade chain from disposable local blueprint copies, validates
entailed edges and verifies their owning blueprint commits are on `origin`.
It never substitutes the user's installed Seihou copies. An unknown entailed
blueprint owner is a preflight failure; add its canonical Mori owner mapping
rather than skipping the check.

Correctness then runs the full existing `verify` suite. A failed preflight or
correctness stage stops immediately, before benchmarks. Once correctness passes,
all six guards run, including after one guard fails, so diagnostics remain
complete. Workloads, committed baselines and numerical ceilings are unchanged.
A failed guard blocks acceptance; never re-record a baseline merely to pass.

The driver retains separate command logs, JSON stage receipts and a manifest in
`keiro/bench/results/release-gates/`. A receipt records its command, exact input
identity, status, time and log checksum. Re-running `just release-gate` reuses
only matching, checksum-verified successful stages less than 24 hours old. Source,
versions, scripts/recipes, baseline, dependency plan, compiler, relevant environment,
local Cabal configuration or PostgreSQL server identity changes invalidate reuse.
Retained evidence and plan 326's execution notes are excluded from source identity;
other documentation edits conservatively invalidate it too. Preflight always
reruns. A newer failure or interrupted attempt supersedes an older pass.

The manifest explicitly references original receipts; never concatenate unrelated
logs into a claimed uninterrupted run. Use `just release-gate --fresh` when new
measurements of every stage are required. Preserve the manifest and every receipt
and log it references in the release evidence commit. `just verify` remains useful
for development but is not the release gate.

Release preparation, the full `verify` recipe, corpus regeneration, archive/docs
building, consumer checks and the release gate share a workspace lock. A competing
writer refuses promptly. Do not run raw Cabal commands against `dist-newstyle`
alongside these commands; raw Cabal does not participate in this lock. The lock
serializes workspace writes, not unrelated projects. Record competing benchmark
load and investigate noisy failures; user authorization for concurrent work does
not waive numerical ceilings.

If an upstream migration changes a recorded checksum in the persistent `jitsurei`
database, apply this release's documented ledger fixup rather than dropping the
database. This rehearses the consumer upgrade guidance. Keep unrelated work out
of the candidate; do not use broad staging to sweep it into a release.

### 5. Commit the candidate and prebuild publication artifacts

Use a Conventional Commit such as `chore(release): <version>` for the prepared
candidate, explaining the PVP bump. Commit only after the step 3 approval already
obtained from the user. Preparation and verification do not require another
approval. Keep the current branch unless the user asks otherwise.

After the gate and native Nix checks pass, build **all sixteen** source/docs
archives before any upload, then test the source archives as an external consumer:

```bash
nix develop -c just release-artifacts
nix develop -c just release-consumer staged
nix develop -c just release-ready keiro/bench/results/release-gates/<run>-manifest.json
```

Artifacts and SHA-256 checksums land in `dist-release/<version>/`. One Haddock invocation targets all eight release packages and is serialized
with verification, avoiding repeated target plans and concurrent Cabal reconfiguration. The staged
consumer depends on all eight packages at the exact shared version, consumes
those tarballs, solves external dependencies only from secure HTTPS Hackage,
builds and serves `/keiro/health` against a freshly migrated disposable database.
It uses an explicit isolated Cabal config and package cache, never the global
HTTP mirror/index or copied credentials. The companion migrator comes from the
matching workspace and is identified in the result; the consumer libraries and
HTTP executable must come from the audited external plan. Cleanup drops only
the newly created scratch database.

`release-ready` reruns preflight and refuses stale/missing stage evidence, newer
failed attempts, changed source, changed archives or a mismatched staged-consumer
proof. It does not upload or tag. Save the artifact inventory and consumer result,
plan and proof log with the release evidence. Commit evidence with an append-only
commit; it must preserve all tested source inputs. Recheck readiness if inputs
change. Do not rerun package tests during publication: the accepted stage receipts
already cover them.

Only after readiness, native Nix checks and the existing user approval, create
all eight annotated tags at the final evidence commit:

```bash
for pkg in keiro-core keiro keiro-pgmq keiro-migrations keiro-test-support keiro-dsl keiro-ops keiro-ops-http; do
  git tag -a "$pkg-<version>" -m "$pkg <version>"
done
git push
git push --tags
```

### 6. Publish the prebuilt archives to Hackage

Use the verified archives under `dist-release/<version>/`. Do not rebuild between
uploads. Publish packages in this order: `keiro-core`, `keiro`, `keiro-pgmq`,
`keiro-migrations`, `keiro-test-support`, `keiro-dsl`, `keiro-ops`, `keiro-ops-http`.
For each package upload its source and documentation:

```bash
cabal upload --publish dist-release/<version>/<pkg>-<version>.tar.gz
cabal upload --publish --documentation dist-release/<version>/<pkg>-<version>-docs.tar.gz
```

Use the Nix shell for uploads too. Publication uses the user's configured Hackage
credentials; isolated consumer configuration intentionally has none. Stop on any
upload failure. Never publish a dependent after a failed dependency upload.
Confirm every package page and docs endpoint returns HTTP 200, then run:

```bash
nix develop -c just release-consumer published
```

Published mode uses exact version constraints with no local release archives. Its
plan must show all eight packages from secure HTTPS Hackage. Index refresh and
dependency solving retry at most five times with 15-second gaps to accommodate
index lag. Compilation and runtime failures are not retried. A failed update is
reported immediately; do not rewrite the global Cabal cache or config to repair
this isolated proof. Retain its result and proof log. Report all eight Hackage
URLs and proceed to the required GitHub release.

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
  links — the release is anchored on `keiro-<version>` only, so the other seven
  tags are otherwise undiscoverable from the release page.
- Verify it landed and is not a draft:
  `gh release view keiro-<version> --json tagName,isDraft,url`
- Report the GitHub release URL when done.

## Important

- Always ask the user to **confirm the version bump and changelogs before
  committing**.
- Always publish in dependency order: **keiro-core → keiro → keiro-pgmq →
  keiro-migrations → keiro-test-support → keiro-dsl → keiro-ops → keiro-ops-http**.
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
