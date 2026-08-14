---
id: 264
slug: release-the-keiro-0-12-0-0-package-set
title: "Release the keiro 0.12.0.0 package set"
kind: exec-plan
created_at: 2026-08-14T13:33:20Z
intention: "intention_01m0075g1kecjb2959gy704yhc"
master_plan: "docs/masterplans/42-fix-the-final-keiro-release-blockers-and-publish-stable-language-5.md"
---

# Release the keiro 0.12.0.0 package set

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, the complete Keiro package family is publicly installable at one shared
0.12.0.0 version: `keiro-core`, `keiro`, `keiro-pgmq`, `keiro-migrations`, `keiro-dsl`, and the
new `keiro-ops`. Each package has an annotated tag, a live Hackage source distribution and
documentation page, and internally consistent PVP bounds. One GitHub release anchored on the
flagship `keiro-0.12.0.0` tag links all six packages and tags.

The release begins only from EP-4's approved release-candidate commit. It re-derives the package
and dependency graph, verifies every default-build dependency against Mori, the authoritative
package registry, and upstream tags, obtains user confirmation before version/changelog edits,
and obtains final approval before commit, push, or upload. Publication stops immediately on a
failed gate or upstream upload.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M0: add `keiro-ops` and `keiro-migrations` to the Mori package inventory and repair the repository release skill to cover all six publishable packages
- [ ] M1: re-derive the last release, changed packages, PVP bump, internal graph, generated-module re-exports, and Hackage prerequisites
- [ ] M1: present the proposed 0.12.0.0 bump and changelog reconciliation to the user and obtain confirmation before edits
- [ ] M2: update all six package versions, every internal PVP bound, and the root plus six package changelogs
- [ ] M2: build source distributions and inspect package contents without publishing
- [ ] M3: run formatting, full verification, Nix, `cabal check`, package tests, source-distribution, and Haddock gates
- [ ] M3: show the complete release diff and obtain final user approval before commit/tag/push/upload
- [ ] M4: create the release commit and six annotated tags, then push them
- [ ] M4: publish source and documentation archives in dependency order and verify every live URL
- [ ] M4: create and verify the GitHub release, then close the MasterPlan and distill any durable ADR context


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- At planning time all six publishable manifests report 0.11.0.0, and the flagship
  `keiro-0.11.0.0` tag is the last shared release anchor. There are 244 commits from that tag to
  reviewed HEAD; implementation must re-count because EP-1 through EP-4 add commits.
- `keiro-ops` was created after the 0.11 release. It has a public library/executable, homepage,
  changelog, and release-set bounds, but no `keiro-ops-*` tag and no Hackage package (the
  authoritative package URL returned 404 on 2026-08-14). It depends on `keiro`,
  `keiro-migrations`, and `keiro-pgmq`, so it must be published last.
- `.agents/skills/release/SKILL.md` and `mori.dhall` predate `keiro-ops`. The skill lists five
  packages, while Mori omits both `keiro-migrations` and `keiro-ops` from the project package
  inventory. A release that trusts either inventory would silently omit the operator package.
- `keiro-test-support` and `jitsurei` remain internal. Test components can depend on the
  unpublished test-support package because Hackage's default consumer build does not enable
  those suites; this known limitation must be reported, not “fixed” by publishing internal
  fixtures during the release.


## Decision Log

Record every decision made while working on the plan.

- Decision: Release six packages, with `keiro-ops` after all of its Keiro dependencies.
  Rationale: The package is a documented public output of MasterPlan 31 and already carries the
  shared version/bounds. Omitting it would make the advertised operator surface unavailable and
  strand its 0.11 metadata without any public artifact.
  Date: 2026-08-14
- Decision: Keep 0.12.0.0 as the proposed shared PVP version, subject to explicit confirmation.
  Rationale: The cycle removes/renames public awakeable exports, publishes a new DSL language
  contract, and includes many breaking changes recorded in the package changelogs. Under the
  repository's PVP policy, 0.11.0.0 to 0.12.0.0 is the established major bump.
  Date: 2026-08-14
- Decision: Repair the local release skill and Mori inventory before preparing artifacts.
  Rationale: Those are durable release inputs. Leaving them stale would reproduce the omission
  on every later release even if this execution handled `keiro-ops` manually.
  Date: 2026-08-14
- Decision: Require two user approvals: proposed version/changelog scope before editing, and the
  complete gated diff before external publication.
  Rationale: The first prevents wasted release preparation under the wrong PVP choice; the
  second protects the irreversible commit/tag/upload boundary with exact evidence.
  Date: 2026-08-14
- Decision: Stop publishing dependents after any failed upload and never move an existing tag.
  Rationale: Hackage publication is immutable and the dependency chain must never advertise a
  package whose required same-version predecessor failed to publish.
  Date: 2026-08-14


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

The release candidate comes from
`docs/plans/263-publish-stable-keiro-dsl-language-5-and-close-the-blocker-review.md`. Read its
recorded code SHA and six follow-up review records before doing anything. All must be approved,
and the current branch must contain that history. The only allowed behavior changes after that
review are release-inventory corrections identified here and metadata/changelog edits; any code
fix returns to EP-4 for a new review.

The six published package manifests are `keiro-core/keiro-core.cabal`, `keiro/keiro.cabal`,
`keiro-pgmq/keiro-pgmq.cabal`, `keiro-migrations/keiro-migrations.cabal`,
`keiro-dsl/keiro-dsl.cabal`, and `keiro-ops/keiro-ops.cabal`. They currently share 0.11.0.0.
`keiro`, `keiro-pgmq`, and `keiro-dsl` depend on `keiro-core`; `keiro-ops` depends on `keiro`,
`keiro-migrations`, and `keiro-pgmq`. Re-derive every occurrence from the manifests because
library, executable, test, or benchmark stanzas may carry separate bounds. `keiro-test-support`
and `jitsurei` are not published and do not receive release tags.

Publish in this dependency-safe order: `keiro-core`, `keiro`, `keiro-pgmq`,
`keiro-migrations`, `keiro-dsl`, then `keiro-ops`. The middle three after `keiro` can be built
independently, but a fixed order makes recovery and reporting deterministic. `keiro-ops` is last
because its solver needs three same-version packages already live.

The release notes have seven authorities: root `CHANGELOG.md` plus one `CHANGELOG.md` under each
published package. The root drives GitHub notes; package files drive Hackage users. Reconcile all
commits since `keiro-0.11.0.0` against them. An in-cycle fix to unreleased code does not need a
separate user-facing bug entry, but every released API change, migration, dependency-bound change,
and Language 5 publication must appear in the appropriate package notes. Preserve `Unreleased`
and move its content under a dated 0.12.0.0 heading.

`.agents/skills/release/SKILL.md` is the operator runbook. Update its package count, dependency
order, version/bound files, test matrix, tag loop, Hackage table, URL verification, and GitHub
package table to include `keiro-ops`. Update `mori.dhall` so `mori show --full` lists
`keiro-migrations` and `keiro-ops` with accurate types/descriptions; retain the already-added
reviews bundle. These inventory changes belong in a small pre-release commit with this plan's
trailers and must pass relevant validation before version preparation.

External dependency investigation follows the repository instructions. Use Mori first to locate
source and docs for the owning projects, including `mori://shinzui/kiroku`,
`mori://shinzui/keiki`, and `mori://shinzui/shibuya`, plus the registered Hasql and Effectful
projects. Then verify the version actually available from Hackage and the authoritative upstream
release tag before accepting bounds. A local Mori checkout may lag; it is context, not the
release-version authority. Inspect `cabal.project` for git pins and prove every dependency in the
default build plan is published. A default-off manual legacy flag may retain an unpublished pin
only when source-distribution and solver checks prove that dependency is unreachable by default.

No ADR governs the mechanical release sequence, and this plan should not create one merely to
record commands. If implementation establishes a durable package-family rule—such as formally
making `keiro-ops` part of every shared-version release—record that in the repository's release
runbook and Mori inventory first; create an ADR only if the rule changes an architectural package
boundary. No cross-repository ADR applies.


## Plan of Work

Milestone 0 repairs release inventory. Update `mori.dhall` and
`.agents/skills/release/SKILL.md` for the six-package set. Run `mori show --full`, Dhall/Mori
validation available in the repository, and release-runbook searches proving every list contains
the same package order. Commit this correction with the MasterPlan, ExecPlan, and Intention
trailers. Do not change package versions yet.

Milestone 1 re-derives the release. Verify all six current versions, the complete set of prior
tags, the flagship anchor, commits and changed package directories, every internal dependency,
public generated-module re-export, and every root/package `Unreleased` entry. Infer the highest
PVP impact. Use Mori to locate each non-boot dependency, then verify Hackage preferred versions
and upstream tags. Run `cabal check` and construct source distributions early enough to catch a
missing source file or unpublished default dependency. Present the proposed 0.12.0.0 bump,
package list/order, dependency evidence, and reconciled release-note outline to the user. Stop
until the user confirms. If the user selects a different version, update this ExecPlan title/body
and the MasterPlan registry before editing metadata.

Milestone 2 prepares release metadata. Change `version:` in all six manifests. Set every bounded
internal library dependency to the confirmed shared PVP version: the three `keiro-core` consumers
and all `keiro-ops` dependencies on the package set. Re-scan rather than relying on this list;
retain deliberately unbounded internal conformance-only stanzas only when the runbook's policy
applies consistently. Verify every generated-code import from `keiro-core` remains available
through `keiro`'s `reexported-modules`. Create dated version sections in root and six package
changelogs and leave empty `Unreleased` headings in place. In particular, `keiro-ops` gets its
first public release notes and breaking upstream bounds; packages with no user-visible changes get
an explicit no-changes statement. Run formatting and build all source distributions. Show the
complete diff but do not commit.

Milestone 3 executes the mandatory gates. Run `nix fmt`, `just verify`, and `nix flake check`.
Run `cabal check` from each package directory, every package test suite, `cabal sdist`, and
Hackage-formatted Haddock generation from the root. Inspect each tarball to ensure changelogs,
license, required generated/runtime files, and migrations are present. Confirm `Keiro.version`
now reports the release version without changing `keiro/src/Keiro.hs`. Confirm all six tags are
absent and the worktree contains only intended release changes. Present the final diff, checksums
or artifact paths, gate results, and proposed tags to the user; stop for final approval.

Milestone 4 publishes exactly the approved tree. Create one Conventional Commit
`chore(release): 0.12.0.0` with a release summary and all three plan trailers. Create six annotated
tags at that commit and push the commit/tags. Upload source and docs in the fixed dependency order,
checking the live package and docs URL after each upload and stopping on failure. After all six
are live, extract the root 0.12.0.0 changelog section into a scratch release-notes file, prepend a
table with all package/tag/Hackage links, create the GitHub release anchored on
`keiro-0.12.0.0`, and verify it is not a draft. Update this plan and MasterPlan outcomes with live
URLs, final SHAs, and any partial-publication recovery facts. Perform the ADR distillation pass;
normally the updated runbook and Mori inventory are sufficient durable memory.


## Concrete Steps

Run general commands from `/Users/shinzui/Keikaku/bokuno/keiro`; only the six `cabal check`
commands run inside package directories.

Verify the EP-4 gate and clean scope:

```bash
git status --short
git log --oneline -n 12
okf validate docs/reviews --strict --profile docs/reviews/profile.dhall --profile-enforce --log-enforce
```

Repair and verify release inventories before version edits:

```bash
mori show --full
rg -n "keiro-core|keiro-migrations|keiro-ops|keiro-dsl" .agents/skills/release/SKILL.md mori.dhall
```

Re-derive release history and versions:

```bash
git tag --list 'keiro-*' 'keiro-core-*' 'keiro-pgmq-*' 'keiro-migrations-*' 'keiro-dsl-*' 'keiro-ops-*'
git log --oneline keiro-0.11.0.0..HEAD
git rev-list --count keiro-0.11.0.0..HEAD
rg -n '^version:' keiro-core/keiro-core.cabal keiro/keiro.cabal keiro-pgmq/keiro-pgmq.cabal keiro-migrations/keiro-migrations.cabal keiro-dsl/keiro-dsl.cabal keiro-ops/keiro-ops.cabal
rg -n -g '*.cabal' 'keiro-core|keiro-migrations|keiro-pgmq|(^|[ ,])keiro([ ,]|$)' keiro-core keiro keiro-pgmq keiro-migrations keiro-dsl keiro-ops
```

Inspect git pins and use Mori before authoritative registry/tag checks:

```bash
rg -n -A5 'source-repository-package' cabal.project
mori registry list
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
mori registry show shinzui/keiki --full
mori registry docs shinzui/keiki
mori registry show shinzui/shibuya --full
mori registry docs shinzui/shibuya
```

Repeat `mori registry search`, `show --full`, and `docs` for every other non-boot dependency
whose source/API/bound needs investigation. Then query Hackage's current preferred-version JSON
and the authoritative upstream tags for every dependency; do not paste a stale list into this
plan. A 404 for a default-build dependency is a hard stop. As of planning, a 404 for
`keiro-ops` itself is expected because this is its first release.

After the first user confirmation, edit metadata/changelogs and run:

```bash
nix fmt
cabal build all --enable-tests
just verify
nix flake check
```

Run package checks:

```bash
(cd keiro-core && cabal check)
(cd keiro && cabal check)
(cd keiro-pgmq && cabal check)
(cd keiro-migrations && cabal check)
(cd keiro-dsl && cabal check)
(cd keiro-ops && cabal check)
cabal test keiro-test keiro-pgmq-test keiro-migrations-test keiro-dsl-test keiro-ops-test
```

Build source and documentation artifacts without uploading:

```bash
for pkgdir in keiro-core keiro keiro-pgmq keiro-migrations keiro-dsl keiro-ops; do
  (cd "$pkgdir" && cabal sdist)
done
for pkg in keiro-core keiro keiro-pgmq keiro-migrations keiro-dsl keiro-ops; do
  cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump "$pkg"
done
```

Confirm metadata-derived versioning and inspect final scope:

```bash
cabal test keiro-test --test-options='--match "package metadata version"'
git diff --check
git diff --stat
git status --short
```

After final approval, create the release commit with this trailer block:

```text
MasterPlan: docs/masterplans/42-fix-the-final-keiro-release-blockers-and-publish-stable-language-5.md
ExecPlan: docs/plans/264-release-the-keiro-0-12-0-0-package-set.md
Intention: intention_01m0075g1kecjb2959gy704yhc
```

Create annotated tags at that one commit:

```bash
for pkg in keiro-core keiro keiro-pgmq keiro-migrations keiro-dsl keiro-ops; do
  git tag -a "$pkg-0.12.0.0" -m "$pkg 0.12.0.0"
done
git push
git push --tags
```

Upload each already-built source and documentation archive from the root in the fixed order.
`set -e` makes the shell stop before a dependent when an upload or live-URL check fails:

```bash
set -e
for release_pkg in keiro-core keiro keiro-pgmq keiro-migrations keiro-dsl keiro-ops; do
  cabal upload --publish "dist-newstyle/sdist/${release_pkg}-0.12.0.0.tar.gz"
  cabal upload --publish --documentation "dist-newstyle/${release_pkg}-0.12.0.0-docs.tar.gz"
  curl -fsS -o /dev/null "https://hackage.haskell.org/package/${release_pkg}-0.12.0.0"
  curl -fsS -o /dev/null "https://hackage.haskell.org/package/${release_pkg}-0.12.0.0/docs/"
done
```

After all six succeed, verify the complete set:

```bash
for pkg in keiro-core keiro keiro-pgmq keiro-migrations keiro-dsl keiro-ops; do
  curl -fsS -o /dev/null "https://hackage.haskell.org/package/$pkg-0.12.0.0"
  curl -fsS -o /dev/null "https://hackage.haskell.org/package/$pkg-0.12.0.0/docs/"
done
```

Create release notes in a `mktemp -d` scratch directory, not the repository. Set
`release_notes_file` to the completed Markdown file containing the six-package link table and
the mechanically extracted root changelog section, then create and verify the GitHub release:

```bash
release_scratch="$(mktemp -d)"
release_notes_file="$release_scratch/release-notes.md"
gh release create keiro-0.12.0.0 --title "keiro 0.12.0.0" --notes-file "$release_notes_file"
gh release view keiro-0.12.0.0 --json tagName,isDraft,url
```


## Validation and Acceptance

Preparation acceptance requires Mori and the release runbook to list the same six publishable
packages, all manifests/changelogs to carry the confirmed release, every internal bound to solve
to that set, no reachable default dependency to exist only as a git pin, and all package contents
to pass `cabal check`. `Keiro.version` must read 0.12.0.0 solely because metadata changed.

Repository acceptance requires clean `git diff --check`, `nix fmt`, `just verify`,
`nix flake check`, all five available package test suites, six source distributions, and six
Hackage Haddock archives. The complete staged diff must match what the user approved. The release
commit has the exact Conventional Commit title and plan trailers; all six annotated tags resolve
to it.

Publication acceptance requires source and docs URLs for all six packages to return success,
with `keiro-ops` visibly available for the first time. No dependent package is uploaded after a
failed prerequisite. The GitHub release is non-draft, anchored on `keiro-0.12.0.0`, and lists all
six tags/Hackage links. The working tree is clean except for any unrelated files explicitly
reported and preserved.


## Idempotence and Recovery

History inspection, formatting, builds, tests, `cabal check`, `sdist`, Haddock generation, and
URL verification are repeatable. Rebuilding an artifact replaces workspace build output but not
source. The version/changelog edits can be revised before approval; preserve unrelated dirty-tree
changes and never use a destructive reset.

Tags and Hackage uploads are not freely reversible. Before tagging, verify each target tag is
absent and the commit SHA is final. Never move or delete a published tag to hide a failure. If an
upload fails before Hackage accepts it, diagnose and retry that same package; do not continue to
its dependents. If the source package is live but documentation upload fails, retry only the docs
archive. If a later package fails after earlier packages are public, record the partial release,
fix forward without changing the version of already-published artifacts, and ask the user before
any new release decision. A GitHub release failure can be retried against the existing flagship
tag after all Hackage packages are live.

Use `mktemp -d` for release-note scratch files and remove it only after the release URL is
verified. Never construct destructive cleanup targets from broad environment variables.


## Interfaces and Dependencies

The shared package set and hard internal order are:

```text
keiro-core 0.12.0.0
├── keiro 0.12.0.0
├── keiro-pgmq 0.12.0.0
└── keiro-dsl 0.12.0.0

keiro-migrations 0.12.0.0

keiro + keiro-pgmq + keiro-migrations
└── keiro-ops 0.12.0.0
```

The source-upload order remains linear for safe stopping:

```text
keiro-core -> keiro -> keiro-pgmq -> keiro-migrations -> keiro-dsl -> keiro-ops
```

Use Cabal/Nix/Just already present in the repository, Mori for local dependency source/docs,
Hackage as the authoritative Haskell package registry, upstream repository tags as the release
authority, `git` for the release commit/tags, and `gh` for the GitHub release. Hackage and GitHub
credentials are external prerequisites; if unavailable, stop before publication and report the
fully prepared state rather than weakening the plan.

The release procedure itself is `.agents/skills/release/SKILL.md`; this plan's M0 updates it to
the six-package reality. If the runbook and this plan disagree after that update, revise both and
record the decision in the parent MasterPlan before proceeding.
