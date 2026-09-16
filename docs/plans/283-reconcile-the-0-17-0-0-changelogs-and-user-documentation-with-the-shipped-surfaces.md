---
id: 283
slug: reconcile-the-0-17-0-0-changelogs-and-user-documentation-with-the-shipped-surfaces
title: "Reconcile the 0.17.0.0 changelogs and user documentation with the shipped surfaces"
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

# Reconcile the 0.17.0.0 changelogs and user documentation with the shipped surfaces

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro 0.17.0.0 is about to be tagged and uploaded to Hackage, and both of those steps
are irreversible. The code in the increment is sound (review record
`docs/reviews/keiro-0-17-release-readiness.md`, REV-17), but the text a consumer reads
about the release is not: the root `CHANGELOG.md`, which becomes the GitHub release
notes, omits several shipped surfaces; the `keiro-dsl` changelog omits every public API
break in the package; two package changelogs are wrong about their own packages; and the
work-queue user reference still tells an operator to inspect the dead-letter queue and
then purge it unconditionally, a sequence the new guarded purge refuses.

After this plan, every `[Unreleased]` section describes exactly what its package ships
in 0.17.0.0, grouped under the release procedure's four headings, with links Hackage can
serve; the work-queue reference describes the inspect, archive-by-id, verify, purge
workflow that the code actually implements; the DSL reference documents `diff --deny`,
the three diagnostic codes it currently omits, the `idempotence` intake clause, and the
language that `keiro-dsl new` skeletons open with; and the user-documentation and reviews
validators pass. You can see it working by reading each changelog against the package
source, by following the DLQ transcript in `docs/user/work-queues.md` against a local
PostgreSQL, and by running `just user-documentation-validate`.


## Progress

- [ ] M1: root `CHANGELOG.md` `[Unreleased]` reconciled against all seven package changelogs.
- [ ] M1: `keiro-dsl/CHANGELOG.md` gains a Breaking Changes list of public API changes, the ledger and check-report notes, the Language 4 comment-only note, and the reworded benchmark bullet.
- [ ] M1: `keiro-test-support/CHANGELOG.md` and `keiro/CHANGELOG.md` corrected.
- [ ] M1: fifo-heads and twin-coverage wording aligned with the sibling plans' outcomes.
- [ ] M2: `docs/user/work-queues.md` "Operating the dead-letter queue" rewritten for the guarded workflow.
- [ ] M3: `docs/user/typed-spec-toolchain.md` documents `diff --deny`, the three missing codes, the `idempotence` clause, and the skeleton language.
- [ ] M3: `docs/user/log.md` entries added and `generated.at` bumped on every touched document.
- [ ] M4: `just user-documentation-validate`, `just reviews-validate`, and `just adr-validate` pass; every changelog claim re-verified against source.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: This plan owns the structure of every `[Unreleased]` section (heading order and
  grouping). Sibling plans that land later append bullets under the headings this plan
  establishes rather than restructuring.
  Rationale: The release skill reconciles the root changelog against the package ones at
  bump time; one owner for the structure keeps that reconciliation mechanical.
  Date: 2026-09-16
- Decision: Document the outbox content-type change under `keiro` "Other Changes", not
  "Breaking Changes".
  Rationale: The type and the API are unchanged; only the header text for retained rows
  stored with non-canonical MIME text changes, and the inbox side normalizes either form.
  Date: 2026-09-16
- Decision: Document the comment-only change to generated Language 4 `QueuePolicy.hs`
  output rather than reverting the generator's comment.
  Rationale: The hand-edited corpora at HEAD already carry the new comment; the freeze
  that matters for published languages is behavior and fold identity, and disclosure is
  cheaper and more honest than a second generator change one day before a release.
  Date: 2026-09-16


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Keiro is a Cabal multi-package workspace. Seven packages are published to Hackage under
one shared version and are released together: `keiro-core`, `keiro`, `keiro-pgmq`,
`keiro-migrations`, `keiro-test-support`, `keiro-dsl`, and `keiro-ops`. Each has its own
`CHANGELOG.md` in its package directory, and the repository root has a `CHANGELOG.md`
that summarizes the release across packages. The root file matters more than it looks:
the release procedure in `agents/skills/release/SKILL.md` (step 7) extracts the root
section for the new version with `awk` and passes it verbatim as the GitHub release
notes. Anything missing from the root is missing from the notes.

Every changelog follows Keep a Changelog with a `## [Unreleased]` section at the top
whose contents become the `## 0.17.0.0 — <date>` section at bump time. Within a section,
the release skill requires exactly these group headings, only when non-empty and in this
order: `### Breaking Changes`, `### New Features`, `### Bug Fixes`, `### Other Changes`.
Two traps from earlier releases (recorded in `docs/reviews/keiro-0-15-release-readiness.md`)
still apply: a relative link in a package changelog must use a `src/` prefix to be served
by Hackage (`/package/keiro-dsl-0.17.0.0/src/CHANGELOG.md` resolves, the bare path does
not), and text must not hard-code the outgoing lockstep bound (`^>=0.16.0.0`), because
the bump rewrites it.

The `[Unreleased]` sections at the reviewed commit (`fa6b66b2`) were compared against
each other by REV-17. The root section mentions the producer-identity change, the pgmq
0.6 adoption, the `Job.jobOrdering` contract, `FifoHeads`, the DSL `ordering fifo-heads`
clause, the reaction runtime, `cancelTimerTx`, `Keiro.Outbox.Identity`, the
`mintIntegrationEvent` deprecation, the `keiro-core` doc change, a benchmark fix, and the
cabal-gild reformat. It contains zero mentions of: redrive, purge, `archiveDlqEntries`,
delegated, `mkPartitionSpec`, `AggGuardRelationUnknown`, or `--deny`. The owning package
changelogs (`keiro-pgmq/CHANGELOG.md`, `keiro-ops/CHANGELOG.md`, `keiro/CHANGELOG.md`,
`keiro-dsl/CHANGELOG.md`) record each of those. `keiro-test-support/CHANGELOG.md` line 11
says "No user-facing changes" although
`keiro-test-support/src/Keiro/Test/Postgres.hs` now exports
`withFreshResourceStorePrepared` (a fixture that clones a database, lets a privileged
store prepare roles or ACLs, then opens the application store; the new `keiro`
access-control test depends on it). `keiro-dsl/CHANGELOG.md` line 64 carries the bullet
"No user-facing changes. The parser-scaling benchmark now uses the current scaffold
`path` and `text` record fields." inside a section that introduces a language candidate.

The surfaces the root section must gain, each verified against source at HEAD:

The dead-letter queue (DLQ) work in `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs`. `redriveDlq`
parses the `original_headers` key of the DLQ wrapper (written by the published
`shibuya-pgmq-adapter` 0.16.0.0) and resends with `sendMessageWithHeaders` when present,
so FIFO group, trace, and application headers survive a redrive; a missing or JSON-null
key stays headerless. `purgeDlq` now returns `PurgeDlqResult`, either
`PurgeDlqPurged count` or `PurgeDlqBlocked hiddenCount`, and refuses when a metrics
snapshot shows rows hidden by a prior read (every `readDlq`, `redriveDlq`, and count-based
`archiveDlq` hides the rows it touches for 30 seconds). `purgeDlqForce` is the
unconditional escape hatch. `archiveDlqEntries` archives specific message ids even while
hidden and returns the ids it moved. `DlqEntry` gains `originalHeaders :: Maybe Value`.

The `keiro-ops` breaking change in `keiro-ops/src/Keiro/Ops/Pgmq.hs` (`runPurge`): the
forced `pgmq dlq purge` calls the guarded library API and returns `Failed` without
deleting when the result is `PurgeDlqBlocked`; `--force` authorizes the mutation after the
preview but does not bypass the refusal. The DLQ JSON output gains `original_headers`.

Delegated inbox intake. `keiro/src/Keiro/Inbox.hs` exports `runInboxDelegated`,
`runInboxDelegatedWithRetries`, and `runInboxDelegatedBatch`, wrappers for consumers whose
downstream operation owns the durable deduplication receipt, so no `keiro_inbox` row is
read or written and no `Store` effect is required. `keiro/src/Keiro/Inbox/Delegated.hs`
exports `delegatedEventId`, `delegatedCommand`, `delegatedFromPMCommand`, and
`DelegatedCommandError`; `keiro/src/Keiro/Inbox/Types.hs` adds `InboxIdempotence`,
`DelegatedOutcome`, and the validated `DelegatedRetryContext`. The durable contract is
`docs/adr/0043-delegated-inbox-intake-uses-a-downstream-event-receipt.md`. On the DSL
side, `keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs` parses an optional
`idempotence table|delegated` clause after `dedupe` (gated to Language 6 through
`optionalLanguageFeature ... DelegatedInboxSyntax`), and the diff classifies a change of
mode as `IntakeIdempotenceModeChanged`.

The Language 6 candidate process reactions in `keiro-dsl`: multiple typed inputs, ordered
input-only guards, optional saga advancement, explicit accepted-only follow-ups,
timer-free processes, and typed timers with rearm, once, cancel, and fire. The runtime it
targets is `keiro/src/Keiro/ProcessManager/Reaction.hs`, whose contract is
`docs/adr/0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md`.
Language 6 is registered as a candidate in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`
(`Candidate CandidateLanguage`); Language 5 remains the sole stable authoring contract.

The transition-family guard-diff rework in `keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs`,
`ReplayImpact.hs`, and `Diff.hs`: live and replay-only transitions are partitioned by
source and command, byte-identical canonical transitions cancel as a multiset before
guard classification, ambiguous emitting remainders emit the advisory
`AggGuardRelationUnknown`, a proposed twin that fails its proof emits
`AggGuardRemedyUnavailable`, and `keiro-dsl diff --deny CODE[,CODE...]` promotes named
advisories to a failing exit (`keiro-dsl/app/Main.hs`). Existing-twin coverage is
syntactic at HEAD: `coversBody` in `Diff.hs` accepts a pre-existing replay-only sibling only
when its guard is byte-canonically the removed region or every old alternative implies it
alone. The remedy pattern itself is
`docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`.

`mkPartitionSpec` and `PartitionSpecConfigError` in `keiro-pgmq/src/Keiro/PGMQ/Job.hs`,
which reject empty, mixed-unit, non-positive, out-of-range, and too-short numeric partition
settings before database access; the raw `PartitionSpec` constructor remains. The
provisioning stance is
`docs/adr/0045-pgmq-provisioning-preserves-upstream-sql-and-bounds-local-retention-validation.md`.
The FIFO consumption contract (`Job.jobOrdering`, `FifoHeads`, the legacy batch-size
refusal) is `docs/adr/0044-fifo-jobs-declare-ordering-and-only-group-heads-batch-safely.md`.

The `keiro-dsl` public API changes that its Breaking Changes section must list. All were
verified with `git diff keiro-0.16.0.0..HEAD -- keiro-dsl/src` and by reading
`keiro-dsl/src/Keiro/Dsl/Grammar.hs` at HEAD: `ProcessNode` (line 938) no longer has
`input`, `handle`, and `timer` fields; it has `body :: ProcessBody`, where `ProcessBody`
(line 840) is `LegacyProcessBody InputDecl HandleNode TimerNode | ReactionProcessBody
ReactionBody`. `IntakeNode` (line 1127) gains `idempotence :: IdempotenceMode`.
`WqOrdering` (line 1240) gains `WqFifoHeads`. `DiagnosticCode` in
`keiro-dsl/src/Keiro/Dsl/Validate.hs` (line 77) gains 34 constructors, from
`ProcessReactionUnknownInput` through `ProcessDispatchIdentityModelChanged`, including
`IntakeIdempotenceModeChanged`, `DelegatedInboxDedupeOnlyPersistence`, the
`ProcessReaction*` and `ProcessTimer*` families, and the fingerprint-version pair.
`LanguageFeature` gains `DelegatedInboxSyntax` and `ProcessReactionSyntax`;
`RuntimeCapability` gains `DelegatedInboxRuntime` (both in `LanguageVersion.hs`).
`DiffEnv` in `Diff.hs` gains `oldService`, `newService`, and `newValidationErrors`.
`ScaffoldReport` in `ScaffoldRun.hs` gains `processReactionCoordinationDrift` and
`processReactionRows`; `ScaffoldRecord` gains `processReactions`; the `Refusal` type in
`ScaffoldRun.hs` gains `HoleContractDrift`. `checkReport` and `workspaceCheckReport` in
`CheckReport.hs` now take a `CheckedService` where they took an
`EffectiveLanguageContract`. `depsForNode` in `Manifest.hs` returns different intake
dependencies per idempotence mode. Nothing was removed or renamed; exhaustive matches and
positional construction break, which the release skill explicitly treats as major.

Two consumer-visible behaviors the changelog also lacks: every legacy process now writes a
`process-reaction ... custom-unverified` row into the scaffold ledger, so the first 0.17
re-scaffold of any existing Language 4 or 5 process service prints a one-time
coordination drift line (informational, not a refusal), and the `check --report-out`
JSON gains a `processReactions` key under the unchanged schema id
`keiro-dsl/check-report/1`. And one generated-output note: commit `da5e2469` changed the
comment the generator emits into every `QueuePolicy.hs`, including Language 4 output
(`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, the string beginning `-- Deployment owns a
positive batch size`); the change is comment-only and does not touch fold identity, but
it is a byte change to frozen generated output that the changelog currently says does not
exist.

The `keiro` package also needs one note: `assembleRow` in
`keiro/src/Keiro/Outbox/Schema.hs` no longer maps the stored `content_type` column through
`parseContentType`; only the exact text `application/json` becomes `ApplicationJson`,
and anything else is preserved verbatim as `OtherContentType`. The Kafka publisher
(`keiro/src/Keiro/Outbox/Kafka.hs`) builds its headers through `integrationHeaders`, so
the `content-type` header for a retained row stored as, say,
`application/json; charset=utf-8` was previously published as `application/json` and is
now published as the stored text. The inbox side (`keiro/src/Keiro/Inbox/Kafka.hs`) still
normalizes through `parseContentType`, so consumers decode either form.

User documentation lives in `docs/user/` (reference) and `docs/guides/` (worked guides).
Both are OKF-profiled bundles: each document has YAML frontmatter with `docId` (a stable
`DOC-N` handle), a `generated.at` timestamp that must advance on a meaningful revision, and
the bundle keeps a `docs/user/log.md` with dated `* **Update**: ...` entries. `just
user-documentation-validate` runs `okf validate --strict --profile
mori/user-documentation-profile.dhall --profile-enforce --log-enforce` over both bundles.
`docs/user/work-queues.md` is `DOC-25`; its "Operating the dead-letter queue" section
(lines 416 to 446 at HEAD) predates this cycle and shows a transcript that reads, redrives,
archives, and then calls `purgeDlq thumbnailJob -- delete everything, permanently`,
followed by "Operators who need an audit trail archive and then purge; operators who do
not can purge alone." The module header of `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` is the
current source of truth for the workflow and contains the corrected snippet.
`docs/user/typed-spec-toolchain.md` documents `check --deny` at lines 2164 to 2185, has a
`### diff` section at line 2292, documents intake syntax at lines 1224 to 1250 (the block
shows `dedupe key ... policy ...` then `persist = dedupe-only`, with no `idempotence`
line), and states at lines 29 to 32 that candidate-only examples begin with
`language keiro-dsl 6`. `docs/guides/evolution-and-replayability.md` lines 449 to 454
already describe `AggGuardRelationUnknown`, `AggGuardRemedyUnavailable`, and
`diff --deny`; the reference does not.

Sibling plans this plan must read before wording two bullets:
`docs/plans/284-gate-ordering-fifo-heads-to-language-6.md` decides whether `ordering
fifo-heads` becomes Language 6 only (its Decision Log will say), and
`docs/plans/286-close-the-carried-over-runtime-dsl-diff-packaging-and-benchmark-follow-ups.md`
decides whether existing-twin coverage is relaxed to semantic equivalence. If either has
not been implemented when this plan runs, describe the behavior at HEAD as it is and leave
a note in this plan's Surprises & Discoveries so the later plan updates the bullet.
`docs/plans/281-restore-a-green-verify-gate-for-the-0-17-0-0-candidate.md` regenerates the
five frozen `QueuePolicy.hs` corpora; the comment-only note in this plan describes that
outcome and does not depend on it.

No cross-repository ADR applies; the relevant local ADRs are cited above.


## Plan of Work

The work is four milestones: changelogs, the DLQ reference, the DSL reference, and
validation. They touch disjoint files, so a reader can do them in any order, but the
changelog milestone should be done first because it fixes the wording that the two
documentation milestones repeat.

Milestone 1 rewrites the `[Unreleased]` sections. Start with the root `CHANGELOG.md`.
Keep the existing bullets, but regroup under the four headings so that every heading is
present at most once and in the required order (at HEAD the root section has "Breaking
Changes", "New Features", and "Other Changes"; add "Bug Fixes" only if a bullet describes
a fix to already-released behavior, which the DLQ header preservation is: pre-0.17
redrive dropped the FIFO group header, so put that bullet under Bug Fixes with the
`keiro-pgmq:` prefix the root uses). Add, prefixed with the owning package name as the
existing bullets are: under Breaking Changes, the `keiro-pgmq` `purgeDlq` result type and
`DlqEntry.originalHeaders` field, and the `keiro-ops` forced-purge refusal; under New
Features, `keiro-pgmq` `purgeDlqForce`, `archiveDlqEntries`, and `mkPartitionSpec`, the
`keiro` delegated intake wrappers and `Keiro.Inbox.Delegated`, and the `keiro-dsl` Language
6 candidate (delegated intake clause and first-class process reactions, stated as a
candidate that leaves Languages 1 through 5 as published); under Other Changes, the
`keiro-dsl` guard-diff rework naming `AggGuardRelationUnknown`,
`AggGuardRemedyUnavailable`, and `diff --deny`. Every added root bullet must be a
condensation of a bullet that already exists in the owning package changelog, never new
information.

Then `keiro-dsl/CHANGELOG.md`. Insert a `### Breaking Changes` bullet list, or extend the
existing one, naming each API change from Context and Orientation: the `ProcessNode`
field replacement, `IntakeNode.idempotence`, `WqOrdering.WqFifoHeads`, the 34 new
`DiagnosticCode` constructors (name the families rather than all 34), the two
`LanguageFeature` and one `RuntimeCapability` additions, the `DiffEnv`, `ScaffoldReport`,
and `ScaffoldRecord` fields, `Refusal.HoleContractDrift`, and the `checkReport` and
`workspaceCheckReport` signature change. State plainly that nothing was removed or
renamed and that exhaustive matches and positional construction are what break. Under
Other Changes add the one-time `custom-unverified` ledger drift line on first re-scaffold,
the `processReactions` key in `keiro-dsl/check-report/1`, and the comment-only change to
generated `QueuePolicy.hs` output for every language including Language 4. Replace the
bullet at line 64 with "Fix the parser-scaling benchmark's access to the current scaffold
`path` and `text` record fields." Read the Decision Log of
`docs/plans/284-gate-ordering-fifo-heads-to-language-6.md`: if it gated the token, change
the New Features fifo-heads bullet to say the clause is a Language 6 addition and, under
Breaking Changes, state that Language 4 and 5 sources that used the token during the
unreleased window must move to Language 6; if it did not, leave the bullet and add the
sentence "Published languages accept this token; see the plan for the recorded
exception." Read the Decision Log of
`docs/plans/286-close-the-carried-over-runtime-dsl-diff-packaging-and-benchmark-follow-ups.md`:
if twin coverage was relaxed, describe the semantic rule; otherwise reword the existing
bullet "Existing replay-only coverage must match the same replay body and cover the exact
removed region or every old alternative" to say explicitly that coverage is syntactic,
that is, the sibling's guard must be byte-canonically equal to the removed region or every
old alternative must imply the sibling's guard alone, and that a hand-simplified but
logically identical twin therefore draws an `AggGuardTightened` advisory that 0.16 did
not emit. Check every relative link in the section: a link to a file inside the package
must be written `src/<file>` and a link to a repository path outside the package must be
an absolute `https://github.com/shinzui/keiro/blob/master/...` URL.

Then the two small corrections. In `keiro-test-support/CHANGELOG.md` replace line 11 with
a `### New Features` bullet: "Add `withFreshResourceStorePrepared`, which clones a database,
runs a privileged preparation callback against a temporary store (for roles and ACLs),
closes it, and then opens the resource-aware application store with modified connection
settings." In `keiro/CHANGELOG.md` add under Other Changes the content-type bullet from
Context and Orientation, including the consumer-visible effect on the published
`content-type` header and the fact that the inbox still normalizes.

Milestone 2 rewrites the "Operating the dead-letter queue" section of
`docs/user/work-queues.md`. Keep the opening sentence that PGMQ does not expire DLQ rows.
Replace the transcript with the workflow from the `Keiro.PGMQ.Dlq` module header: read a
bounded page with `readDlq`, keep the returned `dlqMessageId` values, archive exactly those
ids with `archiveDlqEntries` (which works while the rows are hidden), compare the returned
id set with the requested set and stop if they differ, then call `purgeDlq` and match on
`PurgeDlqPurged n` versus `PurgeDlqBlocked hidden`. Explain in one paragraph why the old
sequence fails: each read hides its rows for 30 seconds, and `purgeDlq` refuses while any
row is hidden. Name `purgeDlqForce` as the unconditional escape hatch that also deletes
hidden rows, and state that the metrics snapshot and the deletion are not atomic, so a
full-queue audit must quiesce producers and other operators first. Update the paragraph on
redrive to say that redriven messages preserve the wrapper's original producer headers
(FIFO group, trace, application metadata) but receive a new message id, a fresh read
count, and a new position at the back of their group, and that a missing or JSON-null
`original_headers` key stays headerless. Update the `DlqEntry` sentence to include
`originalHeaders`. Keep the "Fix the cause before redriving" paragraph. Bump `generated.at`
in the frontmatter to the current UTC time.

Milestone 3 updates `docs/user/typed-spec-toolchain.md`. In the `### diff` section (from
line 2292) add a `--deny CODE[,CODE...]` line to the command block and a sentence
mirroring the `check --deny` paragraph: it is repeatable, it accepts only codes that
`diff` can emit (a `check`-only code is refused rather than ignored), and it promotes the
named advisories to a failing exit for this invocation only. Wherever the reference lists
aggregate evolution codes (search the file for `AggFoldSurfaceChanged` and for the diff
code table), add `AggGuardRelationUnknown` (an append-only advisory: emitting sibling
remainders are ambiguous, no twin is guessed, do not deploy until reviewed),
`AggGuardRemedyUnavailable` (the computed twin failed its render, parse, replay-identity,
or validation proof; no paste-ready transition is printed), and
`IntakeIdempotenceModeChanged` (changing an intake between `table` and `delegated` is a
persisted-identity compatibility break because inbox rows and downstream receipts are not
interchangeable). In the intake syntax block after the `dedupe key ... policy ...` line,
add `idempotence delegated` with a following paragraph: the clause is optional, omission
means `table` in every language, `delegated` requires Language 6 and generates a typed
`runInboxIntake` wrapper over `runInboxDelegated`, and `persist` must not be `dedupe-only`
in delegated mode (the validator reports `DelegatedInboxDedupeOnlyPersistence`). Verify
that last claim by reading the `DelegatedInboxDedupeOnlyPersistence` case in
`keiro-dsl/src/Keiro/Dsl/Validate.hs` before writing it; if the rule differs, write what
the code does. Finally, next to lines 29 to 32, state what `keiro-dsl new` emits: at HEAD
`keiro-dsl/src/Keiro/Dsl/Skeleton.hs` prefixes every skeleton with
`currentAuthoringLanguageVersion`, which is the candidate Language 6. Read the Decision Log
of `docs/plans/285-harden-the-language-6-reaction-candidate-before-it-is-published.md`
first; if it changed the skeleton default to Language 5, document that instead. Bump
`generated.at`. Add one `* **Update**: ...` line per touched document under a
`## 2026-MM-DD` heading for today's date at the top of `docs/user/log.md`, following the
existing entries' style.

Milestone 4 validates. Run the three validators, re-read every new changelog bullet
against the source file it describes, and run the DLQ transcript against a local database
if PostgreSQL is available (the `keiro-pgmq` test suite fixture in
`keiro-pgmq/test/Main.hs`, examples "purgeDlq refuses when inspection has hidden a row and
deletes nothing" and "inspect archive-by-ids and guarded purge completes without waiting",
already prove the sequence; cite them in the section if you do not run it by hand).


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.

Before editing, refresh the evidence so the bullets describe HEAD rather than memory:

```bash
git diff keiro-0.16.0.0..HEAD --stat -- keiro-dsl/src | tail -3
git diff keiro-0.16.0.0..HEAD -- keiro-dsl/src/Keiro/Dsl/Grammar.hs | grep -E '^[+-]\s+(input|handle|timer|body|idempotence) ::'
git diff keiro-0.16.0.0..HEAD -- keiro-dsl/src/Keiro/Dsl/Validate.hs | grep -cE '^\+\s+\| [A-Z]'
sed -n '1,45p' keiro-pgmq/src/Keiro/PGMQ/Dlq.hs
grep -n 'Decision:' docs/plans/284-gate-ordering-fifo-heads-to-language-6.md docs/plans/286-close-the-carried-over-runtime-dsl-diff-packaging-and-benchmark-follow-ups.md docs/plans/285-harden-the-language-6-reaction-candidate-before-it-is-published.md
```

Expected: the Grammar diff shows `-    input :: !InputDecl`, `-    handle :: !HandleNode`,
`+    body :: !ProcessBody`, and `+    idempotence :: !IdempotenceMode`; the Validate count
is `34`; the Dlq header shows the `readDlq` / `archiveDlqEntries` / `purgeDlq` snippet.

Edit the five changelogs with your editor. After editing, confirm the root section now
mentions every surface and that the heading order is correct:

```bash
for k in redrive purgeDlq purgeDlqForce archiveDlqEntries runInboxDelegated 'idempotence delegated' reactions AggGuardRelationUnknown -- --deny mkPartitionSpec 'dlq purge'; do printf '%-28s %s\n' "$k" "$(awk '/^## /{n++} n==1' CHANGELOG.md | grep -c -- "$k")"; done
awk '/^## /{n++} n==1' CHANGELOG.md | grep -n '^### '
```

Expected: every count is at least `1`, and the headings print in the order Breaking
Changes, New Features, Bug Fixes, Other Changes (a heading may be absent, never repeated
or out of order). Repeat the heading check for each package changelog:

```bash
for f in keiro/CHANGELOG.md keiro-pgmq/CHANGELOG.md keiro-dsl/CHANGELOG.md keiro-ops/CHANGELOG.md keiro-test-support/CHANGELOG.md; do echo "== $f"; awk '/^## /{n++} n==1' "$f" | grep -n '^### '; done
grep -n 'No user-facing changes' keiro-dsl/CHANGELOG.md keiro-test-support/CHANGELOG.md | awk -F: '$2 < 20'
grep -n -E '\]\((\.\./|[a-z-]+\.md)' keiro-dsl/CHANGELOG.md | awk -F: '$2 < 80'
```

Expected: the second command prints nothing for `keiro-test-support` and nothing inside
the `keiro-dsl` `[Unreleased]` section; the third prints nothing (no bare or parent-relative
links remain in the unreleased section).

Edit `docs/user/work-queues.md` and `docs/user/typed-spec-toolchain.md`, then stamp the
frontmatter and log:

```bash
NOW=$(date -u +%FT%TZ); echo "$NOW"
grep -n -A2 '^generated:' docs/user/work-queues.md docs/user/typed-spec-toolchain.md | grep 'at:'
head -8 docs/user/log.md
```

Expected: both `at:` values equal `$NOW`, and the log's first dated heading is today with
two `* **Update**:` lines beneath it.

Validate:

```bash
just user-documentation-validate
just reviews-validate
just adr-validate
```

Expected output ends with `OK: 25 concepts (okf_version 0.2)` for `docs/user`,
`OK: 27 concepts (okf_version 0.2)` for `docs/guides`, and `OK: 17 concepts` for the
reviews bundle (counts may be higher if sibling plans added documents; they must not be
lower).

Commit with the trailers the master plan requires:

```text
docs(changelog): reconcile 0.17.0.0 release notes and DLQ user reference

Add the DLQ, keiro-ops purge, delegated inbox, reaction candidate, guard-diff,
and partition-spec surfaces to the root changelog; list keiro-dsl public API
breaks; correct keiro-test-support and keiro; rewrite the guarded DLQ workflow
and document diff --deny, the missing diff codes, and the idempotence clause.

MasterPlan: docs/masterplans/43-address-the-rev-17-keiro-0-17-0-0-release-readiness-findings.md
ExecPlan: docs/plans/283-reconcile-the-0-17-0-0-changelogs-and-user-documentation-with-the-shipped-surfaces.md
Intention: intention_01m2nqd9hre9gbhw37aagtf066
```


## Validation and Acceptance

The change is documentation, so acceptance is that the text is true and the validators
pass. Concretely: a reader who follows the new DLQ transcript in
`docs/user/work-queues.md` against the `keiro-pgmq` test fixture observes `PurgeDlqBlocked
1` after a bare `readDlq` and `PurgeDlqPurged n` after `archiveDlqEntries` returned every
requested id, which is exactly what the examples "purgeDlq refuses when inspection has
hidden a row and deletes nothing" and "inspect archive-by-ids and guarded purge completes
without waiting" in `keiro-pgmq/test/Main.hs` assert (`cabal test keiro-pgmq-test
--test-options='--match "/purgeDlq/"'` prints those examples with a check mark). A reader
who runs `cabal run -v0 keiro-dsl -- diff --help` sees `--deny` listed, matching the new
reference paragraph. Every `keiro-dsl` Breaking Changes bullet names a symbol that
`grep -n` finds in `keiro-dsl/src` at HEAD with the described shape. The root
`[Unreleased]` section contains no sentence that is absent from every package changelog.
`just user-documentation-validate`, `just reviews-validate`, and `just adr-validate` exit 0.


## Idempotence and Recovery

Every step is an ordinary text edit and can be repeated. If a validator fails on
`generated.at` or the log, the message names the document; fix the timestamp format
(`YYYY-MM-DDTHH:MM:SSZ`) or add the missing log line and rerun. If a sibling plan later
changes a fact this plan documented (the fifo-heads language, the twin-coverage rule, the
skeleton default), that plan edits the affected bullet or paragraph and adds its own log
entry; do not revert this plan's wording wholesale. No generated code, corpus, or Cabal
file is touched, so `just verify` is unaffected except through the validators it runs.


## Interfaces and Dependencies

No code interface is created. The documents must agree with these existing interfaces at
HEAD: `Keiro.PGMQ.Dlq` (`readDlq`, `redriveDlq`, `archiveDlq`, `archiveDlqEntries ::
Job p -> [MessageId] -> Eff es [MessageId]`, `purgeDlq :: Job p -> Eff es PurgeDlqResult`,
`purgeDlqForce :: Job p -> Eff es Int64`, `DlqEntry {originalHeaders :: Maybe Value}`);
`Keiro.Inbox` (`runInboxDelegated`, `runInboxDelegatedWithRetries`,
`runInboxDelegatedBatch`), `Keiro.Inbox.Delegated`, and `Keiro.Inbox.Types`
(`InboxIdempotence`, `DelegatedOutcome`, `DelegatedRetryContext`); `Keiro.PGMQ.Job`
(`mkPartitionSpec :: Text -> Text -> Either PartitionSpecConfigError PartitionSpec`);
`Keiro.Outbox.Schema.assembleRow`; the `keiro-dsl` types listed in Context and Orientation;
and the `keiro-dsl diff --deny` option in `keiro-dsl/app/Main.hs`. Tooling used:
`okf` through the `just user-documentation-validate`, `just reviews-validate`, and
`just adr-validate` recipes; `git` for the diffs that ground each bullet. Sibling plans
that may change documented facts: `docs/plans/284-gate-ordering-fifo-heads-to-language-6.md`,
`docs/plans/285-harden-the-language-6-reaction-candidate-before-it-is-published.md`,
`docs/plans/286-close-the-carried-over-runtime-dsl-diff-packaging-and-benchmark-follow-ups.md`.
