---
id: 303
slug: release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests
title: "Release the keiro inspection surface cohort and complete the keiro-ui requests"
kind: exec-plan
created_at: 2026-09-30T23:35:20Z
intention: "intention_01m3taqnt3e6tvd4shm6sfy3a4"
master_plan: "docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T23:35:20Z
---

# Release the keiro inspection surface cohort and complete the keiro-ui requests

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Six improvement requests filed by the keiro runtime UI initiative, IR-26 through IR-31 in
`docs/improvement-requests/`, are implemented by six sibling plans (276, 275, 278, 274, 277,
and 302) under
[MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md).
Each of those plans stops at "locally validated": it leaves its changelog entries undated
under `## [Unreleased]`, records implementation evidence on its request, and keeps the
request short of `completed`, because the repository's convention (the precedent is IR-35 and
its plan 270) is that a request completes only when the release that carries it is on
Hackage and a consumer outside this repository can build against it.

After this plan, one lockstep release of the keiro package set is on Hackage with a new
eighth package, `keiro-ops-http`, published last; the root and per-package changelogs carry
a dated section for that version; the upgrade blueprint carries the edge into it; a scratch
consumer project outside this repository has built against the released packages, mounted the
composed inspection surface, and answered an HTTP request; IR-26 through IR-31 are
`completed` with `completedAt` and a `resolution` naming the release; MasterPlan 45's registry,
Progress, and Outcomes are final; and the durable lessons of the initiative are distilled into
`docs/adr/`. You can see it working by opening
`https://hackage.haskell.org/package/keiro-ops-http` and by running the clean-consumer proof
in Milestone 3, which prints keiro's health body from a process that links only released
packages.

This plan is EP-7 of MasterPlan 45 and hard-depends on EP-1 through EP-6. It does not wait
for the two kiroku-gated listing milestones (plan 274 Milestone 5 and plan 278 Milestone 4):
if `kiroku-store` 0.10.0.0 is not on Hackage when Milestone 1 runs, the cohort ships without
aggregate and process-manager listing, IR-28 and IR-29 record their item 1a as pending, and a
follow-up release carries the listing milestones.


## Progress

- [ ] Milestone 1: preflight: sibling plans complete, the kiroku gate decided, the release
      surface (skill, `justfile`, `README.md`, `mori.dhall`, capability records) verified, the
      documentation audit done, changelogs dated, the version chosen, and the upgrade edge
      written.
- [ ] Milestone 2: the lockstep release: full gate, commit, eight tags, push, eight Hackage
      uploads in dependency order with `keiro-ops-http` last, docs uploads, GitHub release.
- [ ] Milestone 3: the clean-consumer proof, request completion for IR-26 through IR-31,
      MasterPlan 45 closure, and the ADR distillation pass.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Release all six children as one lockstep release rather than one release per
  child.
  Rationale: Five of the six change `keiro-ops` and share the same `[Unreleased]` headings;
  the package set already shares one version by the release skill's rule; and the requests
  complete against a published release, so one release completes all six at once.
  Date: 2026-09-30

- Decision: Do not wait for `kiroku-store` 0.10.0.0. If it is not on Hackage at preflight,
  ship without the two listing milestones and record IR-28 and IR-29 item 1a as pending.
  Rationale: MasterPlan 45's Dependency Graph; the rest of each plan is valuable on its own,
  both plans' recovery sections already allow shipping without listing, and a keiro release
  cannot be blocked on another repository's schedule.
  Date: 2026-09-30

- Decision: The clean-consumer proof is a scratch cabal project outside this repository that
  depends only on released packages and mounts `composeSurfaces` with keiro's surface,
  compiled and run against a migrated database.
  Rationale: A local checkout is not consumer-reachable; the only proof that a release works
  for consumers is a build that never sees this working tree (the lesson recorded in
  MasterPlan 45's memory of prior releases and in kiroku MasterPlan 13's release child).
  Date: 2026-09-30

- Decision: Requests move to `completed` only after the Hackage uploads succeed and the
  consumer proof passes, never at tag time.
  Rationale: Bundle precedent (IR-35, IR-3): `completedAt` and `resolution` name the
  published release.
  Date: 2026-09-30


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The package set and the release skill

This repository publishes seven packages to Hackage under one shared PVP version, in
dependency order: `keiro-core`, `keiro`, `keiro-pgmq`, `keiro-migrations`,
`keiro-test-support`, `keiro-dsl`, `keiro-ops`. `jitsurei` is internal and never released.
Plan 276 adds `keiro-ops-http` as the eighth package, depending on `keiro-ops` and
`keiro-migrations`, so it is uploaded last. The release procedure is the skill at
`agents/skills/release/SKILL.md`; this plan follows it step by step and restates only what a
reader needs to orient. In brief, the skill: reads the current shared version from any cabal
file; finds the last release anchor from the per-package tags (`<pkg>-<version>`, flagship
`keiro-<version>`); decides the bump level from the commits and every `[Unreleased]` section
(a new package, new exports, and new modules are at least minor; a dependency upper-bound
bump on a load-bearing upstream such as `kiroku-store` is major); sets the new `version:` in
every published cabal file and bumps every internal `^>=` bound in the same edit; dates the
`[Unreleased]` sections; writes the upgrade-blueprint edge; runs the mandatory gate (`nix fmt`,
`just verify`, `cabal check` per package, `nix flake check`); commits as
`chore(release): <version>`, creates one annotated tag per package, pushes; uploads each
package with `cabal sdist` then `cabal upload --publish` from the repository root and builds
docs with `cabal haddock --haddock-for-hackage`; and creates the GitHub release anchored on
the flagship tag. The skill says to present the proposed bump and every edit to the user for
confirmation before committing; that rule stands.

The working tree's shared version on 2026-09-30 is 0.19.0.0 (`keiro/keiro.cabal`), which is
also the newest keiro release on Hackage
(`https://hackage.haskell.org/package/keiro/preferred.json`); the anchor tag is
`keiro-0.19.0.0`. Recheck both at preflight.

### The upgrade blueprint

`blueprints/keiro-upgrade/` is a Seihou blueprint whose `blueprint.dhall` carries an
append-only list of migration edges (`S.BlueprintMigration::{ from, to, prompt }`), one per
release that changes what a consumer must do. The skill's step 3 describes it: write the edge
prompt (what changed, precondition, which of this project's validation commands prove it,
what the agent must not do), append the entry with `from` equal to the last release before
the change, declare an upstream edge in `entails` when this release absorbs an upstream
breaking change (a `kiroku-store` 0.10 bound bump would be one, and the upstream edge must be
declared and pushed in the kiroku repository first), bump the blueprint's `version` and the
matching entry in `seihou-registry.dhall`, update `blueprints/keiro-upgrade/README.md`'s edge
table and `blueprints/keiro-upgrade/files/keiro-cohort-versions.md`, then validate with
`seihou validate-blueprint blueprints/keiro-upgrade` and preview with `seihou agent --debug
migrate keiro-upgrade --from <prev> --to <next>`. The preview resolves the blueprint from the
installed copy at `~/.config/seihou/installed/keiro-upgrade`, not the working tree, so it
must be synced from the tree before previewing and restored afterwards, exactly as the skill
shows; a "no migrations declared" result on an unsynced copy is a false negative.

### The requests and their bundle

The six requests live in `docs/improvement-requests/` (an OKF bundle with profile
`mori/improvement-requests-profile.dhall`): `serve-the-keiro-ops-surface-over-http.md`
(IR-26, plan 276), `publish-websocket-live-feeds-over-keiro-wake.md` (IR-27, plan 277),
`expose-aggregate-inspection-read-apis.md` (IR-28, plan 278),
`expose-process-manager-inspection-reads.md` (IR-29, plan 274),
`complete-workflow-inspection-primitives-for-http.md` (IR-30, plan 275), and
`mount-composed-runtime-inspection-surfaces.md` (IR-31, plan 302). Each carries frontmatter
`status`, `plan`, `relatedPlans`, and `timestamp`; a completed request additionally carries
`completedAt` and a multi-line `resolution` naming the plan, the shipped artifacts, the
implementation commits, the tag, and the Hackage release (copy the shape of
`add-an-explicit-terminal-outbox-rejection-outcome.md`). Every change to a request advances
its `timestamp` and appends a dated entry to `docs/improvement-requests/log.md` with `okf log
add docs/improvement-requests --kind <Kind> -m "…"`; the bundle is validated with
`okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce`.
The status vocabulary in use is `proposed`, `accepted`, `in-progress`, `completed`, and
`superseded`.

### The MasterPlan and its children

`docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md` holds
the Exec-Plan Registry (status per child), the Progress checklist (milestone per child), the
Surprises & Discoveries, the Decision Log, and the Outcomes & Retrospective this plan
finalizes. Its Integration Points name the artifacts whose release state this plan verifies:
the `keiro-ops-http` package and its modules, the cursor codec, the pending-timer read, the
hydration primitive, the `AppHooks` fields, the `kiroku-store` bound, the migrations, the OKF
handles, and the changelogs. The MasterPlan's ADR list is the set of records this plan's
distillation pass re-reads: ADR-40 (the stance), ADR-28 (the discipline, extended by three
children), and the new ADRs each child wrote (transport, feeds, aggregate reads,
process-manager reads, composition).

### Documentation surfaces a release audits

Prior releases found that plan-scoped documentation updates miss cross-cutting pages, so each
release audits `docs/user/` and `docs/guides/` (both OKF bundles under
`mori/user-documentation-profile.dhall`, validated by `just user-documentation-validate`),
`docs/capabilities/` (`just capabilities-validate`), `README.md`, and `docs/why-keiro.md`
against the shipped surfaces. For this cohort the pages to check are `docs/user/operations.md`
(the "Operating Keiro" section gained pointers from plans 276, 302, and the read plans),
`docs/user/durable-workflows.md`, `docs/user/process-managers-and-timers.md`,
`docs/user/snapshots.md`, `docs/user/api-reference.md`, `docs/user/live-inspection-feeds.md`
(plan 277), `docs/guides/serve-keiro-ops-over-http.md` (plan 276),
`docs/guides/compose-runtime-inspection-surfaces.md` (plan 302), the capability records
CAP-3, CAP-4, CAP-7, CAP-16, the HTTP-surface record, and the aggregate-inspection record,
and `docs/why-keiro.md` section 5.6, which must still agree with ADR-40.

### ADRs consulted

[ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
records that sister packages cost lockstep versioning and releases alongside the rest of the
package set, which is exactly the cost this plan pays, and that widening the exception is a
new decision; the distillation pass checks whether its Consequences should name the shipped
package. [ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
gained paragraphs from plans 274, 275, and 278; this plan verifies its `timestamp` and log
entries are consistent. No ADR governs the release procedure itself; the skill does.
Cross-repository: kiroku MasterPlan 13's release child (plan 96 in `mori://shinzui/kiroku`)
is the sibling procedure whose clean-consumer proof this plan mirrors.

### Coordination under MasterPlan 45

Hard dependencies: EP-1 (276), EP-2 (275), EP-3 (278), EP-4 (274), EP-5 (277), EP-6 (302),
each marked Complete in the registry, with the exception of the two kiroku-gated milestones.
This plan owns dating the changelogs, the shared version, the release order, the upgrade edge,
the consumer proof, request completion, and the MasterPlan's closure.


## Plan of Work

### Milestone 1: preflight

Scope: establish, with evidence, that the cohort is releasable, and prepare every edit the
release commit needs. At the end, the proposed version, the dated changelogs, the blueprint
edge, and the documentation audit are ready for the user's confirmation, and nothing is
committed.

First, read MasterPlan 45's registry and confirm EP-1 through EP-6 are `Complete`. Open each
child's Progress and confirm every non-gated milestone is checked; for plan 274 Milestone 5
and plan 278 Milestone 4, run
`curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json` and record the
newest version. If a 0.10 release exists and the milestones are unchecked, stop this plan and
have those milestones implemented first (they are their plans' work, not this one's); if no
0.10 release exists, record the decision to ship without listing in this plan's Decision Log
and in MasterPlan 45's, and note that IR-28 and IR-29 will record item 1a as pending.

Second, verify the release surface plan 276 promised: `agents/skills/release/SKILL.md` lists
`keiro-ops-http` as package 8 in the dependency-ordered list, in every `for pkg in …` loop,
and says "all eight"; `justfile`'s `haskell-test` runs `cabal test keiro-ops-http-test`;
`README.md`'s package list has the `keiro-ops-http/` bullet; `cabal.project` lists the
package and carries plan 302's `package keiro-ops-http` flag stanza; `mori.dhall` has the
package block with its dependencies; `keiro-ops-http/keiro-ops-http.cabal` has `version:`
equal to the shared version, `^>=` bounds on the siblings at that version, `extra-doc-files:
CHANGELOG.md`, `LICENSE`, and a `source-repository head`. Fix any gap and record it in
Surprises & Discoveries.

Third, run the documentation audit from Context and Orientation: read each named page and
confirm it describes the shipped behavior (command names as finally implemented, the four
prefixes, the `observed_at` key, the `status_class` vocabulary, the mutation gate, the
NOTIFY caveat verbatim in the feeds guide); confirm every capability record's `interface`
lists the shipped modules and its `since` (for new records) is the version about to ship;
confirm `docs/why-keiro.md` section 5.6 and ADR-40 still agree. Run
`just user-documentation-validate`, `just capabilities-validate`, and `just adr-validate`.

Fourth, choose the version with the skill's step 2: list the commits since `keiro-0.19.0.0`
(or the newer anchor found at preflight), read every `[Unreleased]` section, and infer the
bump. A new package, new modules, new `keiro-ops` exports, and additive metadata on
manager-state events are minor; a `kiroku-store` bound bump to 0.10 is major; an exhaustive
`AppHooks` construction outside this repository would break on the two new fields, which
the skill treats as major for a record consumers construct (check whether `AppHooks` is
constructed positionally anywhere in the Mori dependents with `mori registry dependents
shinzui/keiro --packages`). Present the proposed bump with its justification and wait for
the user's confirmation before editing versions.

Fifth, with the bump confirmed: set the new `version:` in all eight cabal files and every
internal `^>=` bound; date every `[Unreleased]` section in the root `CHANGELOG.md` and in
`keiro/`, `keiro-ops/`, `keiro-migrations/`, `keiro-ops-http/`, and any other package
changelog that has one; write the blueprint edge per Context and Orientation (the prompt
names the new package, the new hook fields a consumer may need to add to a positionally
constructed `AppHooks`, the additive manager-state metadata, the migrations to apply, and,
if applicable, the `kiroku-store` bound move with its `entails` entry), bump the blueprint
version and registry entry, update the README edge table and cohort map, validate the
blueprint, and preview the chain with the installed copy synced from the tree and restored
afterwards. Show every edit to the user.

### Milestone 2: the lockstep release

Scope: the mandatory gate, the commit, the tags, the uploads, and the GitHub release, in the
skill's order. At the end, eight packages at the new version are on Hackage with docs, the
tags are pushed, and the GitHub release is not a draft.

Run the gate: `nix fmt`, `nix develop -c just verify`, `cabal check` from each of the eight
package directories, `nix flake check`. Stop on any failure; a failure inside `just verify`
is read from the log, not inferred from the exit code alone, because the gate stops at the
first failing recipe and later defects surface only on the next run. Re-run `plan.json`'s
acceptance-5 query from plan 276 to confirm no existing package's library gained a web
dependency. Confirm every default-build-plan dependency of every package is on Hackage
(`kiroku-store`, `kiroku-metrics` is test-and-flag only and does not count, `keiki`,
`shibuya`, `pgmq-*`, `pg-migrate`), with `curl` against Hackage, not from memory.

Commit as `chore(release): <version>` with a body summarizing the cohort and the bump level,
and the trailers in Concrete Steps. Create the eight annotated tags at the shared version,
push the commit and the tags. Upload in order `keiro-core`, `keiro`, `keiro-pgmq`,
`keiro-migrations`, `keiro-test-support`, `keiro-dsl`, `keiro-ops`, `keiro-ops-http`: for
each, `cabal check` in the package directory, the package's test suite, `cabal sdist`, then
from the repository root `cabal upload --publish dist-newstyle/sdist/<pkg>-<version>.tar.gz`
and the haddock build and upload the skill shows. A failed post-publish solve is usually
Hackage's index tarball lagging the upload; check the package's `preferred.json` before
treating it as a bad upload. Create the GitHub release anchored on `keiro-<version>` with the
notes extracted from the root changelog and the packages table listing all eight tags, and
verify it is not a draft.

### Milestone 3: consumer proof, request completion, and closure

Scope: prove the release from outside, complete the six requests, close the MasterPlan, and
distill. At the end, IR-26 through IR-31 are `completed`, MasterPlan 45's registry shows
every child `Complete`, and the durable lessons are in `docs/adr/`.

Consumer proof. In a scratch directory outside this repository (use the session's scratchpad
or `mktemp -d`), create a cabal project with one executable that depends on `keiro-ops-http
== <version>`, `keiro-ops == <version>`, `keiro-migrations == <version>`, `kiroku-store`,
`wai`, and `warp`, with no `cabal.project` pointing at any local path and no
`source-repository-package`. Its `Main.hs` opens a store on `DATABASE_URL`, builds
`opsApplication defaultOpsHttpConfig emptyAppHooks store`, composes it with `composeSurfaces
defaultComposeConfig [MountedSurface keiroPrefix app]`, and serves it with
`withOpsHttpServer defaultOpsHttpServerConfig { port = 9093 }`. Run `cabal update`, `cabal
build`, then against a migrated scratch database run the executable and
`curl -s http://127.0.0.1:9093/keiro/health`; the body must be
`{"status":"ok","schema_drift":[],"mutations_enabled":false}`. Record the cabal plan's
resolved versions and the curl output in Surprises & Discoveries. If the solve fails, check
Hackage's index lag before anything else; if the failure is real, the release is defective and
the fix is a follow-up patch release of the affected package, not a rewrite of this one.

Request completion. For each of IR-26 through IR-31: set `status: completed`, add
`completedAt` (the upload time, ISO-8601 UTC), add `resolution` naming the plan, the shipped
modules or commands, the implementation commit range, the tag, and the Hackage release;
advance `timestamp`; where a listing milestone was deferred (IR-28, IR-29 item 1a), say so in
the resolution and keep the request `completed` only if the user agrees that item 1a is
tracked by the follow-up entry in MasterPlan 45's Progress, otherwise leave those two at
`in-progress` with the deferral recorded in the body; append a `Completion` entry to
`docs/improvement-requests/log.md` for each; run the bundle validation. Tick the release
checkboxes in each child plan's Progress if it has any, and add an Outcomes line naming the
release.

MasterPlan closure. In MasterPlan 45: mark EP-7 `Complete` in the registry, check the EP-7
Progress items, add a Progress entry for the deferred listing milestones if any, write the
Outcomes & Retrospective (what shipped, what was deferred, what the parallel-plan
disagreements cost and how the Integration Points resolved them), and record the closing
provenance revision.

Distillation. Re-read the Decision Logs, Surprises & Discoveries, and Outcomes of MasterPlan
45 and all seven children. Decide whether ADR-40's Consequences should gain a paragraph
naming the shipped package and release (an amendment to an existing record: advance its
`timestamp`, log it, validate) and whether any cross-plan lesson (for example, the
first-lands-creates rule for shared modules, or the allocation-at-implementation rule for
migration numbers and OKF handles) deserves its own record or a paragraph in an existing one.
Create or update records with `okf id next` for handles, `okf log add` for the log, and
`just adr-validate`. Then record the memory of the release in the user's project notes if the
session keeps them, and report.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`, inside
the Nix development shell. Every commit carries these trailers after a blank line:

```text
MasterPlan: docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md
ExecPlan: docs/plans/303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md
Intention: intention_01m3taqnt3e6tvd4shm6sfy3a4
```

Milestone 1, evidence gathering:

```bash
grep -n "| Complete |" docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md
for n in 274 275 276 277 278 302; do echo "== $n"; grep -c "^- \[ \]" docs/plans/$n-*.md; done
curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json
curl -fsSL https://hackage.haskell.org/package/keiro/preferred.json
git tag --list 'keiro-*' | sort -V | tail -3
git log --oneline keiro-0.19.0.0..HEAD | wc -l
grep -n "keiro-ops-http" agents/skills/release/SKILL.md justfile README.md cabal.project mori.dhall | head -20
grep -n "^version" */*.cabal
mori registry dependents shinzui/keiro --packages
```

Expected: six `Complete` rows; zero unchecked items per child except the gated milestone
lines of 274 and 278; the kiroku-store and keiro version lists; the anchor tag; a positive
commit count; hits in all five files; eight matching `version:` lines (plus `jitsurei`, which
may differ); the dependents list, used to judge the `AppHooks` breaking-change question.

Milestone 1, blueprint preview (after writing the edge):

```bash
seihou validate-blueprint blueprints/keiro-upgrade
S=$(mktemp -d)
cp -R ~/.config/seihou/installed/keiro-upgrade "$S/keiro-upgrade.bak"
rsync -a --delete blueprints/keiro-upgrade/ ~/.config/seihou/installed/keiro-upgrade/
seihou agent --debug migrate keiro-upgrade --from 0.19.0.0 --to <version>
rsync -a --delete "$S/keiro-upgrade.bak/" ~/.config/seihou/installed/keiro-upgrade/
grep version ~/.config/seihou/installed/keiro-upgrade/blueprint.dhall
```

Expected: validation passes; the preview lists the new edge (and the entailed kiroku edge if
one was declared) in order; the final grep shows the restored installed version.

Milestone 2, the gate and the release (the skill's steps 4 through 7):

```bash
nix fmt
nix develop -c just verify
for pkg in keiro-core keiro keiro-pgmq keiro-migrations keiro-test-support keiro-dsl keiro-ops keiro-ops-http; do (cd "$pkg" && cabal check) || exit 1; done
nix flake check
git add -A && git commit -m "chore(release): <version>" # with body and trailers
for pkg in keiro-core keiro keiro-pgmq keiro-migrations keiro-test-support keiro-dsl keiro-ops keiro-ops-http; do git tag -a "$pkg-<version>" -m "$pkg <version>"; done
git push && git push --tags
```

Then, per package in that order, the sdist, upload, and haddock commands the skill shows,
each followed by `curl -fsSL https://hackage.haskell.org/package/<pkg>/preferred.json` to
confirm the version appears. Finally the GitHub release:

```bash
S=$(mktemp -d)
awk '/^## <version>/{f=1;next} /^## 0.19.0.0/{exit} f' CHANGELOG.md > "$S/relnotes-body.md"
gh release create keiro-<version> --title "keiro <version>" --notes-file "$S/relnotes.md"
gh release view keiro-<version> --json tagName,isDraft,url
```

Milestone 3, the consumer proof:

```bash
C=$(mktemp -d) && cd "$C"
cabal init --non-interactive --minimal --exe --package-name keiro-ops-http-consumer >/dev/null
# edit the cabal file's build-depends and Main.hs as described in Plan of Work
cabal update
cabal build 2>&1 | tail -3
DATABASE_URL="host=$PGHOST dbname=keiro_consumer_proof user=$USER" cabal run keiro-ops-http-consumer &
sleep 2 && curl -s http://127.0.0.1:9093/keiro/health; kill %1
cabal build --dry-run 2>&1 | grep -E "keiro|kiroku"
```

Expected: the build ends without error, the curl prints keiro's health body, and the dry run
lists only released versions.

Milestone 3, bundle work:

```bash
okf log add docs/improvement-requests --kind Completion -m "IR-26 … completed in keiro <version>"
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
okf id next docs/adr --profile docs/adr/profile.dhall ADR
just adr-validate
bun agents/skills/exec-plan/record-provenance.ts revision --plan docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md --model <your-model-id> --harness <harness> --mode implement --note "EP-7 complete; MasterPlan closed"
```


## Validation and Acceptance

The release is accepted when: `curl -fsSL https://hackage.haskell.org/package/<pkg>/preferred.json`
lists the new version for all eight packages; `gh release view keiro-<version>` reports
`isDraft: false`; the consumer proof prints
`{"status":"ok","schema_drift":[],"mutations_enabled":false}` from a build whose plan names
only released versions; and `git tag --list '*-<version>'` prints eight tags.

Request completion is accepted when `okf validate` on the improvement-requests bundle
passes with IR-26 through IR-31 at `completed` (or IR-28 and IR-29 at `in-progress` with the
deferral recorded, if the user chose that), each with `completedAt` and `resolution`, and
`docs/improvement-requests/log.md` carries a dated entry per request.

MasterPlan closure is accepted when every registry row is `Complete`, every Progress item is
checked (or a deferred-milestone entry exists for the listing work), Outcomes & Retrospective
is written, and the provenance revision is recorded.

Distillation is accepted when `just adr-validate` passes after any ADR change and the
MasterPlan's Outcomes names which records were created or amended and why (or states that
none were needed, with the reason).


## Idempotence and Recovery

Milestone 1 writes only uncommitted edits and can be redone from a clean tree with
`git checkout -- .` before the user's confirmation. Version bumps, changelog dating, and the
blueprint edge are one commit; if the gate fails after the commit, fix forward with a new
commit before tagging, never amend a pushed commit. Tags are created only after the gate;
if an upload fails partway, stop, do not upload dependents, and resolve before continuing;
already-uploaded packages stay published (Hackage uploads are irreversible), so a defective
upstream package is fixed by a patch release, and the remaining packages are uploaded against
it. A failed post-publish solve or a missing version in `preferred.json` minutes after upload
is usually the Hackage index tarball lagging; wait and re-check before acting. The consumer
proof is a scratch directory and can be recreated freely. Request and MasterPlan edits are
plain file edits validated by `okf`; a failed validation is fixed in place. The installed
blueprint copy must be restored after the preview; confirm with the final `grep` in Concrete
Steps, because a synced copy left behind makes the next release's preview lie.


## Interfaces and Dependencies

This plan writes no code. It consumes: the release skill (`agents/skills/release/SKILL.md`),
the Seihou blueprint tooling (`seihou validate-blueprint`, `seihou agent --debug migrate`),
the OKF tooling (`okf log add`, `okf validate`, `okf id next`), the provenance script
(`agents/skills/exec-plan/record-provenance.ts`), `cabal`, `gh`, `curl`, and Mori
(`mori registry dependents shinzui/keiro --packages` for the breaking-change check). The
released artifacts it verifies are those the sibling plans define: `keiro-ops-http` with
`Keiro.Ops.Http` (transport, feeds, and composition), `keiro` with `Keiro.Inspection.Cursor`,
`Keiro.Workflow.Inspection`, `Keiro.Inspection.Aggregate`, `Keiro.ProcessManager.Inspect`,
the `Keiro.Timer` pending read, the `Keiro.Command` hydration primitive, and the shard views;
`keiro-ops` with the new commands, hooks, and exports; and `keiro-migrations` with the new
migrations and the exported verifier session. The consumer proof's cabal file depends on
`keiro-ops-http == <version>`, `keiro-ops == <version>`, `keiro-migrations == <version>`,
`kiroku-store` at keiro's released bound, `wai`, and `warp`, and nothing else.
