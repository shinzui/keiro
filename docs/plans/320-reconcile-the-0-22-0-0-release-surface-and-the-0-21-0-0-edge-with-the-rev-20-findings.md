---
id: 320
slug: reconcile-the-0-22-0-0-release-surface-and-the-0-21-0-0-edge-with-the-rev-20-findings
title: "Reconcile the 0.22.0.0 release surface and the 0.21.0.0 edge with the REV-20 findings"
kind: exec-plan
created_at: 2026-10-21T12:21:07Z
intention: "intention_01m5f6g7yje5csts3eztsgvnws"
master_plan: "docs/masterplans/46-address-the-rev-20-review-findings-and-the-command-path-performance-regression.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T12:21:07Z
---

# Reconcile the 0.22.0.0 release surface and the 0.21.0.0 edge with the REV-20 findings

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, every document a consumer reads at release time tells the truth about what
shipped. The root and package changelogs use only the four headings the release skill allows
and name every consumer-visible change the review found missing, with record-construction
breaks under Breaking Changes. The release skill's internal-dependency scan matches the
`keiro-ops` bounds it must bump. The Mori registry's dependency constraints agree with the
cabal files. The 0.20.0.0 to 0.21.0.0 upgrade edge and the `keiro-dsl` 0.21.0.0 notes say that
regeneration rewrites every aggregate's `BehaviorContract.hs` and name the public API changes
the release omitted. The stale "`read` is read-only" sentence is gone from the user reference.
Plan 303 then cuts 0.22.0.0 from a reconciled surface.


## Progress

- [ ] M1: Changelogs are normalized and complete. The `[Unreleased]` sections of
      `CHANGELOG.md`, `keiro/CHANGELOG.md`, `keiro-migrations/CHANGELOG.md`,
      `keiro-ops/CHANGELOG.md`, and `keiro-ops-http/CHANGELOG.md` use only `### Breaking
      Changes`, `### New Features`, `### Bug Fixes`, and `### Other Changes`, carry no bullet
      outside a heading, and include the entries listed in Context; what plans 317, 318, and
      319 ship is described as shipped.
- [ ] M2: The release skill's dependency scan and the registry are correct. The regex in
      `agents/skills/release/SKILL.md` step 3 matches `keiro-ops` and `keiro-ops-http`, and
      `mori.dhall`'s `effectful` and `effectful-core` constraints equal the cabal bounds.
- [ ] M3: The 0.21.0.0 record is corrected. `blueprints/keiro-upgrade/migrations/0.20.0.0-to-0.21.0.0.md`
      states the real regeneration scope and the API changes; `keiro-dsl/CHANGELOG.md` carries
      an erratum under `[Unreleased]` for the 0.21.0.0 section; `seihou validate-blueprint
      blueprints/keiro-upgrade` passes.
- [ ] M4: User documentation lines are fixed. `docs/user/operations.md` describes `pgmq dlq
      read` as a reservation that needs `--force`; `docs/user/durable-workflows.md` and
      `docs/user/process-managers-and-timers.md` carry the legacy-only wording from plan 319
      if its extension did not land; `just user-documentation-validate` passes.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Correct the published 0.21.0.0 edge's prompt text in place and add an erratum to
  the `keiro-dsl` changelog, rather than writing a new edge.
  Rationale: Edges are append-only as a list, but a prompt is guidance that may be corrected;
  a consumer crossing 0.20.0.0 to 0.21.0.0 later should read the right scope. The published
  0.21.0.0 changelog section is immutable on Hackage, so the erratum goes under `[Unreleased]`
  and ships with 0.22.0.0.
  Date: 2026-10-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

A Keiro release is cut by `agents/skills/release/SKILL.md`: it bumps the eight package versions
in lockstep, reconciles changelogs, writes an upgrade edge in `blueprints/keiro-upgrade/`, runs
the gate, tags, and uploads. The root `CHANGELOG.md` feeds the GitHub release notes; each package
has its own `CHANGELOG.md`; the skill requires exactly the headings Breaking Changes, New
Features, Bug Fixes, and Other Changes. REV-20
(`docs/reviews/keiro-0-20-0-21-unreleased-review.md`, "Required before tagging", items 1, 2,
6, and 7, and the findings on `keiro-dsl`) recorded the following defects at commit
`a62850d3`, which this plan fixes.

The root `[Unreleased]` section opens with four bullets under no heading and uses a
`### Performance` heading; `keiro-migrations/CHANGELOG.md` has an empty `### New Features` and
a `### Added`; `keiro-ops/CHANGELOG.md` has `### Changed` and `### Added`;
`keiro-ops-http/CHANGELOG.md` has `### Added`. Missing from the root changelog: `pgmq dlq read`
is now a mutation on the CLI (a non-forced read exits 1 with a preview); `OpsOutcome` gains the
`InspectionFailed` constructor (`keiro-ops/src/Keiro/Ops/Render.hs:37`), which breaks exhaustive
matches in embedders and appears in no changelog; `wf list` and `wf show` JSON gain
`status_class`, `wf steps` entries gain `recorded_at`, `wf show` orders awakeables by
`(created_at, awakeable_id)` and children by `(created_at, child_id, child_name)` from the
owner tables, `wf show/steps/journal` return `InspectionFailed` where they returned `Failed`
text, `shard status` gains `observed_at`, `heartbeat_at`, `updated_at`, and
`lease_age_seconds`; `Keiro.Migrations.SchemaCheck.verifyExpectedSchemaSession` is only in the
package changelog. `RunCommandOptions.inspectionProvenance` and the `AppHooks` fields
`aggregates` and `processManagers` are record-construction breaks listed under New Features.
Plans 317, 318, and 319 add their own entries (cursor order and removed error, the new
`deliveryDeadlineSeconds` limit and the 403/415 refusals, the reaction inspector and the
legacy-only wording); this plan writes them once those plans have shipped, describing what is
in the tree.

The release skill's step 3 regex `keiro-core|keiro-migrations|keiro-pgmq|keiro-test-support|(^|[ ,])keiro([ ,]|$)`
does not match `keiro-ops`, so the five `keiro-ops ^>=0.21.0.0` bounds in
`keiro-ops-http/keiro-ops-http.cabal` (lines 83, 110, 135, 167, 207) and the one in
`jitsurei/jitsurei.cabal` (line 166) are invisible to someone following it. `mori.dhall`
declares `effectful` and `effectful-core` at `>=2.6 && <2.7` in five places while the cabal
files carry `effectful >=2.6 && <2.8` and `effectful-core >=2.6 && <2.7 || >=2.7.1.1 && <2.8`
since 0.19.0.1.

The 0.21.0.0 release regenerated every aggregate's `BehaviorContract.hs` (47 files, 2,079
insertions between the 0.20.0.0 and 0.21.0.0 tags under `keiro-dsl/test/`) for Languages 3,
4, 5, and 6, and the witness-backed harness change applies to every language that carries
`ExplicitTransitionImplementationSyntax` (2 and later), while
`blueprints/keiro-upgrade/migrations/0.20.0.0-to-0.21.0.0.md` line 65 scopes regeneration to
"hole-owned live initial transitions". The `keiro-dsl` 0.21.0.0 Breaking Changes omit:
`Keiro.Dsl.Expression.TypedScalarNode` gaining `TypedMappedLift` and `TypedMappedInitial`;
`ExpressionDiagnosticCode` gaining four constructors; `LanguageFeature` gaining two;
`Keiro.Dsl.TypeGraph.MappedDeclError` gaining `InvalidMappedWriteLift`; `DiagnosticCode`
(`Enum`, `Bounded`) gaining eight constructors in the middle of its order, so `fromEnum`
positions after `ContractTypeIdDomainChanged` and `AggGuardRemedyUnavailable` shift; the
`MappingIdentity` ledger JSON gaining an optional `writeLift` key; `Scaffold.behaviorRequirementsFor`
newly exported and partial; `ScaffoldRun.pureRefusalsForService` gaining the
`generatedImportResolutionViolations` refusal class; and a reclassification of same-prefix
literal-to-declared id-domain transitions whose old revision predates
`ContractIdDomainTypeIdV7` from advisory to breaking.

`docs/user/operations.md` line 147 says "`read` is read-only and decodes visible entries" two
lines under a console block that shows `--force`; `Keiro/Ops/Pgmq.hs` and ADR-53 say the read
reserves messages for 30 seconds and is a mutation.

Relevant local ADRs: ADR-49
(`docs/adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md`) frames
the legacy-only wording; ADR-16
(`docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`) is the
published-language freeze that the 0.21.0.0 regeneration crossed and the edge must describe;
ADR-53 for the `dlq read` reservation. No cross-repository ADR applies.


## Plan of Work

Milestone 1 rewrites the five `[Unreleased]` sections. Move the headingless root bullets under
the right headings, fold `### Performance`, `### Added`, and `### Changed` into the four allowed
headings, delete the empty heading, move the two record-construction breaks under Breaking
Changes, and add the missing entries. Then diff `git log --oneline keiro-0.21.0.0..HEAD`
against the root section and confirm every shipped surface is represented, including plans
317 to 319 once they land.

Milestone 2 edits the skill regex to
`keiro-core|keiro-migrations|keiro-pgmq|keiro-test-support|keiro-ops-http|keiro-ops|(^|[ ,])keiro([ ,]|$)`
with a sentence explaining why `keiro-ops` needs its own alternative, and updates the five
`effectful` constraints in `mori.dhall` to the cabal bounds; verify with
`mori registry show shinzui/keiro --full`.

Milestone 3 corrects the edge and the changelog. In `0.20.0.0-to-0.21.0.0.md`, replace the
scope sentence with one that says every aggregate's `BehaviorContract.hs` is rewritten on
regeneration (new `behaviorObligationReport` export and `coverageReportFor`) and that harnesses
of Language 2 and later services with hole-owned initial edges change too, and list the API
changes above. Add a `0.21.0.0 erratum` paragraph under `keiro-dsl/CHANGELOG.md` `[Unreleased]`
with the same content. Validate the blueprint with `seihou validate-blueprint
blueprints/keiro-upgrade`; the blueprint version does not change because no edge was added.

Milestone 4 fixes the user documentation lines, carries the legacy-only wording from plan 319
if needed, and runs the validator.


## Concrete Steps

From the repository root inside `nix develop`:

```bash
git log --oneline keiro-0.21.0.0..HEAD
git diff keiro-0.21.0.0..HEAD -- CHANGELOG.md keiro/CHANGELOG.md keiro-ops/CHANGELOG.md keiro-ops-http/CHANGELOG.md keiro-migrations/CHANGELOG.md
grep -n '^###' CHANGELOG.md keiro/CHANGELOG.md keiro-migrations/CHANGELOG.md keiro-ops/CHANGELOG.md keiro-ops-http/CHANGELOG.md | awk -F: '$3 !~ /Breaking Changes|New Features|Bug Fixes|Other Changes/'
rg -n -g '*.cabal' 'keiro-core|keiro-migrations|keiro-pgmq|keiro-test-support|keiro-ops-http|keiro-ops|(^|[ ,])keiro([ ,]|$)' keiro-core keiro keiro-pgmq keiro-migrations keiro-test-support keiro-dsl keiro-ops keiro-ops-http | grep -c 'keiro-ops '
seihou validate-blueprint blueprints/keiro-upgrade
just user-documentation-validate
```

Expected: the `awk` line prints nothing once M1 is done (no heading outside the four); the
`grep -c` prints `5`; the blueprint validation and the documentation validator exit 0.


## Validation and Acceptance

M1: the heading check prints nothing and every entry named in Context is present in the root
changelog. M2: the regex check counts the five `keiro-ops` bounds and `mori registry show
shinzui/keiro --full` reports the `effectful` constraints as `>=2.6 && <2.8`. M3: the edge
text names the regeneration scope and the API changes and the blueprint validates. M4: the
validator passes and `grep -n 'read-only' docs/user/operations.md` finds nothing about `dlq
read`. The behavioural proof is plan 303's release rehearsal reading a surface it does not
have to correct.


## Idempotence and Recovery

Documentation and metadata edits only; `git checkout` restores any file. Do not edit the
published `## 0.21.0.0` changelog sections themselves; the erratum goes under `[Unreleased]`.


## Interfaces and Dependencies

`CHANGELOG.md` and the five package changelogs; `agents/skills/release/SKILL.md` step 3 (step
4 is owned by plan 316); `mori.dhall`; `blueprints/keiro-upgrade/migrations/0.20.0.0-to-0.21.0.0.md`;
`docs/user/operations.md`, `docs/user/durable-workflows.md`,
`docs/user/process-managers-and-timers.md`; the `seihou` and `okf` validators. Soft
dependencies: plans 317, 318, and 319 (this plan describes what they ship). Plan 303 consumes
the result. No parent milestone must be accepted before this plan begins, but its M1 should
close after those three plans.
