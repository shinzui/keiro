---
id: 282
slug: write-the-0-16-0-0-to-0-17-0-0-upgrade-edge-and-reconcile-release-metadata
title: "Write the 0.16.0.0 to 0.17.0.0 upgrade edge and reconcile release metadata"
kind: exec-plan
created_at: 2026-09-16T18:25:28Z
intention: "intention_01m2nqd9hre9gbhw37aagtf066"
master_plan: "docs/masterplans/43-address-the-rev-17-keiro-0-17-0-0-release-readiness-findings.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-16T18:25:28Z
---

# Write the 0.16.0.0 to 0.17.0.0 upgrade edge and reconcile release metadata

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro publishes its upgrade knowledge as a Seihou blueprint, `blueprints/keiro-upgrade/`,
which declares one agent-guided "edge" per released version window that requires a consumer to
change source, fixtures, or database state. A consumer runs `seihou agent migrate keiro-upgrade`
and Seihou walks the consumer's checkout across every declared edge between the version it
resolved and the version it wants. The blueprint currently ends at the `0.15.0.0 -> 0.16.0.0`
edge. The 0.17.0.0 release changes several public APIs in ways that do not compile or do not
behave the same for a consumer on 0.16.0.0, so the release procedure in
`agents/skills/release/SKILL.md` makes an edge mandatory, and the release-readiness review
`docs/reviews/keiro-0-17-release-readiness.md` (REV-17) lists the missing edge as a
tag-blocking item.

After this plan, a consumer on 0.16.0.0 that runs the migration sees a `0.16.0.0 -> 0.17.0.0`
step whose prompt names every API it must change and every behavior it must re-check, the
blueprint's own version and its mirror in the repository-root `seihou-registry.dhall` advance,
the README edge table and the cohort map carry the 0.17.0.0 row, and two pieces of release
metadata that drifted during the cycle are corrected: the `mori.dhall` bound for
`shibuya-pgmq-adapter` matches the Cabal files, and the release skill describes the formatter
the repository actually uses. You can see it working by validating the blueprint with
`seihou validate-blueprint blueprints/keiro-upgrade` and by previewing the chain with
`seihou agent --debug migrate keiro-upgrade --from 0.16.0.0 --to 0.17.0.0` against a synced
installed copy, which must print exactly one step owned by `keiro-upgrade`.


## Progress

- [ ] Milestone 1: `blueprints/keiro-upgrade/migrations/0.16.0.0-to-0.17.0.0.md` written with precondition, dependency alignment, code adaptation, DSL-consumer effects, and validation sections.
- [ ] Milestone 1: the `ordering fifo-heads` paragraph of the edge reflects the outcome recorded in `docs/plans/284-gate-ordering-fifo-heads-to-language-6.md`.
- [ ] Milestone 2: `blueprints/keiro-upgrade/blueprint.dhall` declares the `0.16.0.0 -> 0.17.0.0` migration and its `version` is `0.6.0`.
- [ ] Milestone 2: `seihou-registry.dhall` mirrors version `0.6.0`.
- [ ] Milestone 2: `blueprints/keiro-upgrade/README.md` version line and edge table updated.
- [ ] Milestone 2: `blueprints/keiro-upgrade/files/keiro-cohort-versions.md` has the 0.17.0.0 row.
- [ ] Milestone 3: `seihou validate-blueprint blueprints/keiro-upgrade` passes.
- [ ] Milestone 3: synced-copy preview shows the new step; installed copy restored and the restore confirmed.
- [ ] Milestone 4: `mori.dhall` `shibuya-pgmq-adapter` constraint is `^>=0.16.0.0`.
- [ ] Milestone 4: `agents/skills/release/SKILL.md` describes cabal-gild instead of cabal-fmt.
- [ ] `just verify` documentation validators and `nix flake check` pass on the changed tree.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Declare no `entails` on the new edge.
  Rationale: `git diff keiro-0.16.0.0..HEAD -- '*.cabal'` moves only the pgmq family
  (`>=0.5 && <0.6` to `>=0.6 && <0.7`) and `shibuya-pgmq-adapter` (`^>=0.14.0.0` to
  `^>=0.16.0.0`); the `kiroku-store`, `kiroku-store-migrations`, `keiki`, and `shibuya-core`
  bounds are unchanged and `keiro-migrations/migrations/` did not change, so no upstream
  blueprint declares an edge this release must cross first. The pgmq and adapter moves are
  ordinary dependency bumps a consumer's solver resolves, not judgement work owned by another
  blueprint.
  Date: 2026-09-16
- Decision: Bump the blueprint version from `0.5.0` to `0.6.0`.
  Rationale: Every previous edge addition bumped the minor component (0.15 to 0.16 moved
  `0.4.0` to `0.5.0`), and an added edge is an additive change to the blueprint's contract.
  Date: 2026-09-16
- Decision: Keep the edge's `fifo-heads` paragraph conditional on
  `docs/plans/284-gate-ordering-fifo-heads-to-language-6.md` and finalize it last.
  Rationale: Whether a consumer must raise a spec to Language 6 to use `ordering fifo-heads`
  is decided by that plan; writing the paragraph before that decision would ship an edge that
  contradicts the shipped grammar.
  Date: 2026-09-16
- Decision: Correct `mori.dhall` and the release skill's formatter text in this plan rather
  than in the release commit.
  Rationale: Both are release metadata with no consumer-visible effect, the release skill
  forbids widening the release commit beyond versions, bounds, changelogs, and the edge, and
  leaving them for "later" is how the `mori.dhall` drift happened in the first place.
  Date: 2026-09-16


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Keiro is a Haskell event-sourcing framework published as seven Hackage packages that share one
version: `keiro-core`, `keiro`, `keiro-pgmq`, `keiro-migrations`, `keiro-test-support`,
`keiro-dsl`, and `keiro-ops`. The repository is a Cabal multi-package workspace with a `just`
task runner and a Nix flake. The version about to be released is 0.17.0.0; the last released
version is 0.16.0.0, tagged `keiro-0.16.0.0` at commit `2da45585`.

A "blueprint" is a directory Seihou (`seihou`, installed on this machine at
`~/.nix-profile/bin/seihou`) reads to drive an agent through a migration. The Keiro blueprint
lives in `blueprints/keiro-upgrade/` and has these parts:

- `blueprint.dhall` declares the blueprint's `name`, `version`, a `prompt` (the file
  `prompt.md`, mounted for every edge), a `versionProbe` shell snippet that reads which Keiro
  version a consumer's build plan resolved, one `files` entry (`files/keiro-cohort-versions.md`,
  mounted read-only), and a `migrations` list of `S.BlueprintMigration` records, each with
  `from`, `to`, and `prompt = ./migrations/<file>.md as Text`, optionally with `entails`, a list
  of exact upstream edges to run first. Today the list ends with
  `from = "0.15.0.0", to = "0.16.0.0", prompt = ./migrations/0.15.0.0-to-0.16.0.0.md`.
- `migrations/` holds one Markdown prompt per edge. The two most recent are
  `0-14-to-0-15.md` (a breaking release, with numbered steps) and
  `0.15.0.0-to-0.16.0.0.md` (a runtime and migration change, with Precondition, Align
  dependencies and rollout, Adapt, and Validate sections). The newer naming uses full
  versions; use it.
- `README.md` documents the blueprint for consumers and maintainers. Line 9 is
  `**Version:** \`0.5.0\``; the "Declared edges" table (lines 35 to 42) lists one row per edge
  with its `Entails` column; the "For maintainers" section (from line 71) states that an edge
  is added in the same change that cuts a release and explains `entails`, edge preconditions,
  validation, and the preview trap described below.
- `files/keiro-cohort-versions.md` is a table of which upstream bounds each Keiro release
  declares (`kiroku-store`, `kiroku-store-migrations`, `keiki`, `shibuya-core`), newest first,
  plus notes on deprecated upstream releases and PostgreSQL coverage.
- `seihou-registry.dhall` at the repository root registers the blueprint for installation;
  its `keiro-upgrade` entry at line 22 carries `version = Some "0.5.0"` and must always equal
  `blueprint.dhall`'s version.

Seihou resolves a blueprint from its *installed* copy under
`~/.config/seihou/installed/keiro-upgrade`, not from this working tree. That copy is currently
at version `0.1.0`, so previewing a freshly authored edge reports "No blueprint migrations are
declared inside the requested version window", which is a false negative. The release skill's
step 3 documents the workaround: back up the installed copy, `rsync` the working tree over it,
preview, then restore and confirm the restore. This plan repeats those commands.

The consumer-visible changes this edge must describe were verified by REV-17 against the
working tree at `fa6b66b2`:

- `Keiro.PGMQ.Job.Job` (`keiro-pgmq/src/Keiro/PGMQ/Job.hs`) gained the required field
  `jobOrdering :: JobOrdering`. `JobOrdering` now has four constructors: `Unordered`,
  `FifoThroughput`, `FifoRoundRobin`, and the new `FifoHeads`. `validateJobConsumptionConfig`
  runs at the start of `jobProcessorWithContext` (line 844) and `runJobOnceWithContext`
  (line 984) and throws `JobConsumptionConfigError` (line 371) as an exception when the
  explicit `JobTuning.ordering` differs from `jobOrdering` (`JobOrderingMismatch`), when the
  raw tuning fails `mkJobTuning` (`InvalidJobTuning`), or when `FifoThroughput` or
  `FifoRoundRobin` is combined with `batchSize > 1` (`UnsafeLegacyFifoBatch`). The
  convenience wrappers `jobProcessor` (line 867) and `runJobOnce` (line 1166) now derive
  their tuning with `withOrdering job.jobOrdering defaultJobTuning`, so an `Unordered` job
  behaves as before. `FifoHeads` maps to the adapter's grouped-head read and needs PGMQ 1.12 or
  later on the PostgreSQL server (`docs/user/work-queues.md` line 337).
- `Keiro.Outbox.enqueueProducerEventTx` (`keiro/src/Keiro/Outbox.hs`) changed from
  `IntegrationProducer e -> OutboxId -> IntegrationEventDraft -> Eff es (Tx.Transaction ())` to
  `IntegrationProducer e -> RecordedEvent -> Word32 -> IntegrationEventDraft ->
  Tx.Transaction ProducerEnqueueOutcome`. It derives the outbox id and the message id from the
  producer's source, name, the source event id, and the emission index (use `0` for a mapper
  that emits one draft per event), and the message id is now opaque text of the form
  `<namespace>_v1_<sha256-hex>` rather than a TypeID. It returns `ProducerInserted`,
  `ProducerDuplicateIdentical`, or `ProducerIdentityConflict` with the differing field classes.
  `mintIntegrationEvent` is deprecated in favour of `freshIntegrationEvent`, which is the
  explicitly fresh escape hatch. `mkIntegrationProducer` now rejects an empty
  `messageIdPrefix`. `Keiro.Outbox` re-exports the new module `Keiro.Outbox.Identity`, whose
  records `ProducerIdentity` (`outboxId`, `messageId`, `derivationVersion`) and
  `ProducerEventKey` (`sourceEventId`, `emissionIndex`) share field names with
  `OutboxMessage` and `IntegrationEvent`; because `keiro` compiles with
  `DuplicateRecordFields`, a consumer that imports `Keiro.Outbox` unqualified and uses those
  names as bare selector functions now gets an ambiguous-occurrence error, while record-dot,
  `OverloadedLabels`, and pattern matching are unaffected. `KeiroMetrics`
  (`keiro/src/Keiro/Telemetry.hs`) gained the field `outboxIdentityConflict`, which any code
  that constructs the record directly must supply. Historical random message ids cannot be
  recovered from the new derivation, so an existing producer must drain in-flight attempts and
  keep its committed checkpoint before switching, as
  `docs/adr/0042-producer-outbox-identity-is-a-versioned-source-event-contract.md` records.
- `Keiro.PGMQ.Dlq` (`keiro-pgmq/src/Keiro/PGMQ/Dlq.hs`): `purgeDlq` now returns
  `PurgeDlqResult` (`PurgeDlqPurged count` or `PurgeDlqBlocked hiddenCount`) and refuses to
  delete while a metrics snapshot shows rows hidden by a prior `readDlq`, `redriveDlq`, or
  `archiveDlq`; `purgeDlqForce` is the unconditional form; `archiveDlqEntries` archives
  specific ids even while hidden; `DlqEntry` gained `originalHeaders :: Maybe Value` and
  `redriveDlq` re-sends those headers. `keiro-ops`' `pgmq dlq purge --force` now calls the
  guarded API and fails without deleting when rows are hidden.
- `Keiro.PGMQ.Metrics` re-exports pgmq's `QueueMetrics`, which in the pgmq 0.6 family gained
  the nullable field `defaultPartitionLength`; positional matches and direct construction
  must account for it. The dependency bounds move to `pgmq-config`, `pgmq-core`,
  `pgmq-effectful`, `pgmq-hasql` (and test-only `pgmq-migration`) `>=0.6 && <0.7` and
  `shibuya-pgmq-adapter ^>=0.16.0.0`; a consumer with tighter pins must move them together.
- `Keiro.Timer.cancelTimerTx` and `Keiro.ProcessManager.Reaction` are additive and need no
  consumer change; the edge should mention that switching an existing manager name to the
  reaction runner is an identity migration requiring a drain
  (`docs/adr/0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md`),
  and that delegated inbox intake is opt-in
  (`docs/adr/0043-delegated-inbox-intake-uses-a-downstream-event-receipt.md`).
- DSL consumers (`keiro-dsl`): generated `QueuePolicy.hs` modules now export `jobOrdering`,
  and the hand-owned `WorkqueueJob.hs` that fills the `Job` record must add
  `jobOrdering = QueuePolicy.jobOrdering` (compare
  `keiro-dsl/test/conformance-dispatch-full/HospitalCapacity/ReservationWork/WorkqueueJob.hs`
  line 27 with the generated policy at
  `keiro-dsl/test/conformance-dispatch-full/Generated/HospitalCapacity/ReservationWork/QueuePolicy.hs`
  lines 10 to 15). `Keiro.Dsl.ScaffoldRecord.processReactionRowsForService`
  (`keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` line 328) now writes a
  `process-reaction {...}` ledger row with `verification = "custom-unverified"` for every
  legacy process, so the first 0.17 scaffold of an existing Language 4 or 5 process service
  prints a one-time informational coordination drift line for each process and rewrites the
  ledger; it is not a refusal, and 0.16 ledgers parse under 0.17 because unknown rows are
  filtered by prefix. The check-report JSON gained the `processReactions` key under the
  unchanged schema id `keiro-dsl/check-report/1` (`keiro-dsl/src/Keiro/Dsl/CheckReport.hs`
  line 117). Whether `ordering fifo-heads` is accepted only under Language 6 or under every
  published language is decided by `docs/plans/284-gate-ordering-fifo-heads-to-language-6.md`.

Relevant ADRs, by repository-relative path:
`docs/adr/0042-producer-outbox-identity-is-a-versioned-source-event-contract.md` (frozen
identity derivation, no schema migration, drained cutover for historical ids);
`docs/adr/0044-fifo-jobs-declare-ordering-and-only-group-heads-batch-safely.md` (the job
declares its ordering, tuning must match, only grouped heads batch safely);
`docs/adr/0043-delegated-inbox-intake-uses-a-downstream-event-receipt.md`;
`docs/adr/0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md`.
No ADR governs the blueprint itself; its contract is the README's "For maintainers" section
and the release skill.


## Plan of Work

### Milestone 1: write the edge prompt

At the end of this milestone the file
`blueprints/keiro-upgrade/migrations/0.16.0.0-to-0.17.0.0.md` exists and reads as a complete
instruction to an agent upgrading one consumer project. Model it on
`migrations/0.15.0.0-to-0.16.0.0.md` and `migrations/0-14-to-0-15.md`: a title
`# Keiro 0.16.0.0 → 0.17.0.0`, a one-paragraph summary saying the upstream cohort
(`kiroku-store >=0.8 && <0.9`, `kiroku-store-migrations ^>=0.4.0.0`, `keiki >=0.9 && <0.10`,
`shibuya-core ^>=0.9.0.0`) is unchanged and no upstream edge is entailed, then these sections.

"Precondition": apply the edge when the project depends on any Keiro package; the sub-steps
each state their own applicability (a project without `keiro-pgmq` skips the work-queue step,
a project without a canonical `IntegrationProducer` skips the outbox step, a project without
`keiro-dsl` skips the DSL step). Tell the agent to report an inapplicable step as not
applicable and never to exit nonzero for it, because a nonzero exit is reported as a provider
failure and halts every remaining edge (README "For maintainers").

"Step 1 — Align dependencies": raise every Keiro package to 0.17.0.0; move `pgmq-*` bounds to
`>=0.6 && <0.7` and `shibuya-pgmq-adapter` to `^>=0.16.0.0` if the project names them; do not
move the Kiroku, Keiki, or Shibuya cohort bounds; report solver conflicts rather than adding
`allow-newer` or git overrides. State that `FifoHeads` requires PGMQ 1.12 or later on the
server and that a consumer must confirm the server version before adopting it.

"Step 2 — Work queues": add `jobOrdering` to every `Job` value; make explicit
`JobTuning` orderings match the declaration (or derive them with
`withOrdering job.jobOrdering defaultJobTuning`); replace any legacy FIFO ordering combined
with a batch size above one either by `FifoHeads` or by batch size one, because the old
combination now throws `JobConsumptionConfigError` at processor construction or the first
one-shot read; adapt positional matches on `QueueMetrics` for `defaultPartitionLength`;
change `purgeDlq` callers to inspect `PurgeDlqResult`, use `archiveDlqEntries` for inspected
ids, and use `purgeDlqForce` only where unconditional deletion was intended; add
`originalHeaders` to any exhaustive `DlqEntry` construction or match. For `keiro-ops` users,
note that `pgmq dlq purge --force` now refuses hidden rows.

"Step 3 — Outbox producers": rewrite `enqueueProducerEventTx` calls to the new signature,
passing the recorded source event and emission index `0` for single-draft mappers, and handle
the three outcomes (condemn the checkpoint transaction on `ProducerIdentityConflict` and
call `recordProducerEnqueueOutcome` once after the runner returns); replace
`mintIntegrationEvent` with `freshIntegrationEvent` only where a fresh envelope is really
intended; supply `outboxIdentityConflict` in any direct `KeiroMetrics` construction; qualify
or record-dot any bare `outboxId`, `messageId`, or `sourceEventId` selector that becomes
ambiguous through the `Keiro.Outbox.Identity` re-export. State the cutover rule from ADR-42:
drain in-flight old attempts, keep the committed checkpoint, do not replay pre-cutover
history under the new policy without an application-owned mapping, and keep source, producer
name, namespace, and emission-index assignments stable.

"Step 4 — Process managers and inbox": no change is required; say explicitly that
`Keiro.ProcessManager.Reaction` and the delegated inbox wrappers are additive, and that a
manager name must not be switched to the reaction runner without the drain in ADR-41.

"Step 5 — DSL consumers": add `jobOrdering = QueuePolicy.jobOrdering` to hand-owned
`WorkqueueJob` fills; expect and accept the one-time `custom-unverified` process-reaction
ledger rows on the first re-scaffold and commit the rewritten ledger; expect the
`processReactions` key in check reports; and, depending on the outcome of
`docs/plans/284-gate-ordering-fifo-heads-to-language-6.md`, either state that
`ordering fifo-heads` is available only in a Language 6 spec (so a published-language spec
must keep a legacy ordering with batch size one) or state that every published language
accepts it. Do not write this paragraph until that plan's Outcomes section records its
decision; the Progress entry for it stays unchecked until then.

"Validate": run the consumer's normal build and tests; run any work-queue integration test
against a PGMQ 1.12 server if `FifoHeads` was adopted; confirm that a `purgeDlq` call site
handles `PurgeDlqBlocked`. Name this repository's own gates, `cabal build all` and
`just verify`, as the reference validation, exactly as the previous edges do. Close with the
prohibitions the previous edges use: no `allow-newer`, no hand-edited generated files, no
ad hoc SQL against Keiro tables, no automatic cutover of historical message ids.

Acceptance for the milestone is that the file renders as Markdown, every fenced block has a
language tag, and every API name in it exists in the working tree (check with `grep -rn` in
`keiro/src` and `keiro-pgmq/src`).

### Milestone 2: declare the edge and bump the blueprint version

Append to the `migrations` list in `blueprints/keiro-upgrade/blueprint.dhall`, after the
`0.15.0.0 -> 0.16.0.0` entry:

```dhall
      , S.BlueprintMigration::{
        , from = "0.16.0.0"
        , to = "0.17.0.0"
        , prompt = ./migrations/0.16.0.0-to-0.17.0.0.md as Text
        }
```

Change `version = Some "0.5.0"` to `version = Some "0.6.0"` at line 7 of `blueprint.dhall`
and at line 22 of `seihou-registry.dhall`. In `blueprints/keiro-upgrade/README.md`, change
line 9 to `**Version:** \`0.6.0\`` and append the row
`| \`0.16.0.0\` | \`0.17.0.0\` | — |` to the "Declared edges" table after the
`0.15.0.0 | 0.16.0.0` row. In `blueprints/keiro-upgrade/files/keiro-cohort-versions.md`, add
the row `| 0.17.0.0 | \`>=0.8 && <0.9\` | \`^>=0.4.0.0\` | \`>=0.9 && <0.10\` |
\`^>=0.9.0.0\` |` above the 0.16.0.0 row. The cohort columns do not cover pgmq or the adapter,
so add one sentence under the table saying that 0.17.0.0 also requires the pgmq 0.6 family and
`shibuya-pgmq-adapter` 0.16.0.0, so that a consumer answering "what else moves" sees it.

Acceptance is that `grep -n 'version = Some' blueprints/keiro-upgrade/blueprint.dhall
seihou-registry.dhall` prints `0.6.0` twice and the README table and cohort map show the new
rows.

### Milestone 3: validate and preview

Run `seihou validate-blueprint blueprints/keiro-upgrade` from the repository root; it must
exit 0 and report the blueprint valid. Then preview the chain against a synced installed copy
(the installed copy is at `0.1.0` and would otherwise report no migrations in the window):

```bash
S=$(mktemp -d)
cp -R ~/.config/seihou/installed/keiro-upgrade "$S/keiro-upgrade.bak"
rsync -a --delete blueprints/keiro-upgrade/ ~/.config/seihou/installed/keiro-upgrade/
seihou agent --debug migrate keiro-upgrade --from 0.16.0.0 --to 0.17.0.0
rsync -a --delete "$S/keiro-upgrade.bak/" ~/.config/seihou/installed/keiro-upgrade/
grep version ~/.config/seihou/installed/keiro-upgrade/blueprint.dhall
ls ~/.config/seihou/installed/keiro-upgrade/migrations/
```

The preview contacts no provider and writes nothing. It must list exactly one step, the
`0.16.0.0 -> 0.17.0.0` edge, labelled as owned by `keiro-upgrade`, with no entailed step. The
final two commands must show the installed copy back at `0.1.0` with its original migrations
directory; leaving the synced copy behind would make the next release's preview lie in the
opposite direction.

### Milestone 4: reconcile release metadata

In `mori.dhall`, the `Schema.Dependency.WithAugmentation` entry whose `name` is
`"shinzui/shibuya-pgmq-adapter:shibuya-pgmq-adapter"` (around line 219) has
`versionConstraint = Some "^>=0.15.0.0"`; change it to `Some "^>=0.16.0.0"` so it equals the
bound in `keiro-pgmq/keiro-pgmq.cabal` (lines 74 and 108) and `jitsurei/jitsurei.cabal`
(line 174). Verify with `mori show --full` or `dhall type` that the file still evaluates.

In `agents/skills/release/SKILL.md`, three passages still describe the old formatter: line
182 ("every changed line must be a version, an internal bound, or `cabal-fmt` realignment"),
line 353 (`nix fmt           # treefmt: fourmolu + cabal-fmt + nixpkgs-fmt`), and lines 385
to 388 ("`cabal-fmt` realigns the `build-depends` version column whenever a bound's width
changes ..."). The repository has formatted with cabal-gild since commit c337e183
(`nix/treefmt.nix` line 19 enables `programs.cabal-gild`), and cabal-gild does not align a
version column; it normalizes each `build-depends` entry onto its own line. Rewrite the three
passages to name cabal-gild and describe its actual effect (a bound edit changes only that
line; if `nix fmt` rewrites more than the edited lines, the file was not gild-formatted and
the reflow should be committed once), keeping the blind-replace trap and the "diff each cabal
file against HEAD" instruction intact.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

Confirm the starting state:

```bash
tail -8 blueprints/keiro-upgrade/blueprint.dhall
ls blueprints/keiro-upgrade/migrations
grep -n 'version = Some' blueprints/keiro-upgrade/blueprint.dhall seihou-registry.dhall
grep -n 'versionConstraint = Some "^>=0.15.0.0"' mori.dhall
grep -n 'cabal-fmt' agents/skills/release/SKILL.md
```

Expected: the last migration is `from = "0.15.0.0"`, the directory has four files, both
version lines say `0.5.0`, `mori.dhall` matches once (line 225), and the skill matches at
lines 182, 353, and 385.

Confirm every API name the edge will cite:

```bash
grep -n 'jobOrdering ::\|FifoHeads\|^data JobConsumptionConfigError' keiro-pgmq/src/Keiro/PGMQ/Job.hs
grep -n '^enqueueProducerEventTx ::\|^freshIntegrationEvent ::\|module Keiro.Outbox.Identity' keiro/src/Keiro/Outbox.hs
grep -n 'PurgeDlqResult\|purgeDlqForce\|archiveDlqEntries\|originalHeaders ::' keiro-pgmq/src/Keiro/PGMQ/Dlq.hs
grep -n 'outboxIdentityConflict ::' keiro/src/Keiro/Telemetry.hs
```

Each grep must print at least one line; if one prints nothing, the API changed after this
plan was written and the edge text must follow the working tree, not this plan.

Write the edge (Milestone 1), then the declaration and version bumps (Milestone 2), then run:

```bash
seihou validate-blueprint blueprints/keiro-upgrade
```

Expected output ends with a line reporting the blueprint valid and exit status 0. Then run the
sync-preview-restore block from Milestone 3 and compare its output with the expectation there.

Apply Milestone 4 edits, then run the repository's documentation and formatting gates:

```bash
just adr-validate research-validate capabilities-validate reviews-validate user-documentation-validate
nix flake check
```

Both must exit 0. Commit with a Conventional Commits message such as
`docs(blueprint): add the 0.16.0.0 to 0.17.0.0 upgrade edge` and the trailers:

```text
MasterPlan: docs/masterplans/43-address-the-rev-17-keiro-0-17-0-0-release-readiness-findings.md
ExecPlan: docs/plans/282-write-the-0-16-0-0-to-0-17-0-0-upgrade-edge-and-reconcile-release-metadata.md
Intention: intention_01m2nqd9hre9gbhw37aagtf066
```


## Validation and Acceptance

The edge is accepted when all of the following hold. `seihou validate-blueprint
blueprints/keiro-upgrade` exits 0. The synced preview
`seihou agent --debug migrate keiro-upgrade --from 0.16.0.0 --to 0.17.0.0` prints one step
owned by `keiro-upgrade` for `0.16.0.0 -> 0.17.0.0` and no entailed steps, and afterwards
`grep version ~/.config/seihou/installed/keiro-upgrade/blueprint.dhall` prints `0.1.0`
again. `grep -c 'cabal-fmt' agents/skills/release/SKILL.md` prints `0` and `grep -c
'cabal-gild' agents/skills/release/SKILL.md` prints at least `1`. `grep -n
'shibuya-pgmq-adapter' -A6 mori.dhall | grep versionConstraint` shows `^>=0.16.0.0`. Every
API name in the edge resolves with the greps in Concrete Steps. A reader who knows only
0.16.0.0 can follow the edge to adapt a project that uses FIFO work queues, a canonical
producer, DLQ purge, and a scaffolded service; the reviewer of this plan should walk one such
project (the in-repository `jitsurei` package is a usable stand-in for the work-queue step:
its `jitsurei/src/Jitsurei/ShipmentNotices.hs` already carries `jobOrdering = FifoHeads`).


## Idempotence and Recovery

Every edit is a plain text change to tracked files; rerunning any step is safe. The preview
block copies the installed blueprint before overwriting it; if it is interrupted after the
`rsync` and before the restore, run the restore line and the two confirmation commands by
hand, using the `$S/keiro-upgrade.bak` directory it created. If `seihou
validate-blueprint` reports a Dhall error, the usual cause is a missing comma before the
appended `S.BlueprintMigration` record or a prompt path that does not exist; fix the file and
rerun. Nothing in this plan touches a database, a package version, or a tag.


## Interfaces and Dependencies

This plan edits only documentation, Dhall metadata, and the release skill; it compiles no
Haskell. It reads these interfaces to describe them accurately: `Keiro.PGMQ.Job` (`Job`,
`JobOrdering`, `JobTuning`, `withOrdering`, `defaultJobTuning`, `jobProcessorWithContext`,
`runJobOnceWithContext`, `JobConsumptionConfigError`), `Keiro.PGMQ.Dlq` (`purgeDlq`,
`purgeDlqForce`, `archiveDlqEntries`, `PurgeDlqResult`, `DlqEntry`), `Keiro.PGMQ.Metrics`
(`QueueMetrics`), `Keiro.Outbox` (`enqueueProducerEventTx`, `freshIntegrationEvent`,
`mintIntegrationEvent`, `mkIntegrationProducer`, `recordProducerEnqueueOutcome`, the
`Keiro.Outbox.Identity` re-export), `Keiro.Telemetry` (`KeiroMetrics`), and
`Keiro.Dsl.ScaffoldRecord` / `Keiro.Dsl.CheckReport` for the DSL ledger and report changes.
It depends softly on `docs/plans/284-gate-ordering-fifo-heads-to-language-6.md` for the
`fifo-heads` paragraph and on
`docs/plans/283-reconcile-the-0-17-0-0-changelogs-and-user-documentation-with-the-shipped-surfaces.md`
for consistency of wording with the root changelog; neither blocks starting this plan. The
tools used are `seihou` (installed at `~/.nix-profile/bin/seihou`), `rsync`, `just`, `nix`,
and `mori`.
