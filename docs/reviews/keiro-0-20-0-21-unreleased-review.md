---
type: Review
title: Keiro 0.20.0.0, 0.21.0.0 and unreleased increment review
description: The 0.19.0.1 to HEAD increments change no per-event Keiro code on the runtime hot paths and the unreleased inspection cohort is bounded where it claims to be, but the committed command benchmark guard is red at HEAD with every append-heavy scenario 25% to 239% slower than its August baseline, the default workflow listing scans the whole ledger per page under a wide-key split whose index was withdrawn, the HTTP surface admits cross-site confirmed mutations and lets slow readers hold every permit, process-manager inspection covers only the legacy API that the 1.0 plan retires, 0.21.0.0 regenerated published-language output beyond what its edge states, and the release surface for the next tag is not yet in the tree.
generated:
  by: process:claude-code
  at: "2026-10-21T11:46:37Z"
reviewId: REV-20
subject: mori://shinzui/keiro
subjectKind: project
reviewedSha: a62850d33f47db60c55e91012f24c9a2a9e0ed3b
coverage: incremental
baseSha: 9b215c1121a694e49d582d9bb4e8600a3b9b446f
previousReview: REV-19
reviewedAt: "2026-10-21T11:46:37Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5-1
effort: high
outcome: changes-requested
dimensions:
  - correctness
  - performance
  - design
  - test-coverage
  - documentation
  - operability
context: >-
  Reviewed the 106 commits between the keiro-0.19.0.1 tag and HEAD as three
  increments (0.20.0.0, 0.21.0.0, and the unreleased inspection cohort) for
  correctness, API-contract soundness and, first of all, performance regression
  on the runtime hot paths, against the retained evidence and against fresh
  measurements taken at the reviewed commit. The keiro runtime, keiro-migrations,
  keiro-test-support, keiro-pgmq, jitsurei, the dependency cohort, the
  benchmark evidence and the release surface were read in full by this
  reviewer; the keiro-dsl 0.21.0.0 increment and the keiro-ops and
  keiro-ops-http increment were read by two delegated reviewers whose findings
  were re-verified in the code where they bear on the verdict. The owner's
  stated direction toward 1.0.0.0 with Language 6 as the only surviving DSL
  language (ADR-49, plan 304) is used as the frame for the design findings.
  This record continues the chain from REV-19.
---

# Keiro 0.20.0.0, 0.21.0.0 and unreleased increment review

## Verdict

Changes requested before the next tag. On the question that motivated this
review, the Keiro code on the runtime hot paths is clean: the command cycle,
process-manager dispatch, the subscription workers, the workflow writer, the
outbox, the inbox and PGMQ consumption are either untouched across the three
increments or changed only on startup paths, the one shared helper on the
command path (`hydrateUsing`) was measured in five alternating pairs with no
cost, and the unreleased writer schema is byte-identical to 0.21.0.0 after the
stored-class candidate that cost 9.22% of writer capacity was withdrawn. The
measurements are not clean. The committed command benchmark guard, run fresh
for this review on a quiet machine, is red at HEAD: every scenario that
appends is 25% to 239% slower than its August baseline while every scenario
that only hydrates and decides is an order of magnitude faster, which places
the slowdown in the event-store substrate rather than in Keiro's code.
Rebuilt and rerun at the 0.19.0.1 tag, the same guard already fails nine of
fifteen scenarios with the same shape, so the regression against the August
baseline predates these windows and went unnoticed because the guard is
outside `just verify`; a paired comparison between 0.19.0.1 and HEAD shows at
most a small, order-sensitive difference on router fan-out. The
producer-identity ratio guard and the first fresh inbox scenario are red as
well. Every other repository gate passes at
HEAD: 65 Haskell suites with no failure, the thirteen policy and
documentation gates, `cabal check` in all eight packages, the corpus policy,
the jitsurei demos, the migrations suite and the flake check.

What needs to change is on the read side, the HTTP surface and the release
surface. The default `wf inspect list` page sequentially scans `keiro_workflows`
twice for a wide-key population that no index now distinguishes, and its
chosen key order cannot use the primary key, so every page costs the whole
ledger; both are about to become public contract. The HTTP transport accepts a
confirmed mutation from any origin and lets a handful of slow readers hold
every inspection permit, which also takes `/health` down. The process-manager
inspection and provenance ship only for the legacy positional API that plan
304 retires before 1.0. The 0.21.0.0 release regenerated `BehaviorContract`
and some harness modules for every published language while its edge says
only hole-owned initial transitions regenerate. And the next release has no
version, edge, or reconciled changelogs in the tree yet, while the release
skill's own dependency scan would miss the six `keiro-ops` bounds it must
bump.

## Hot-path performance

The surfaces below are the paths a running Keiro service exercises per
command, per event, per job or per workflow step. For each, what changed in
the three increments, the evidence, and the assessment.

| Hot path | What changed | Evidence | Assessment |
| --- | --- | --- | --- |
| Command hydration (`Keiro.Command.hydrateAfterProbe`) | Unreleased: the probe became `hydrateUsing (\_ result -> result)` with an `INLINE` pragma so the inspection-only `hydrateWithSource` can share it | `keiro/bench/results/inspection/hydration-core-path`: five alternating before/after pairs over snapshot hit, miss, corrupt seed, no codec and a 10,000-event replay, plus the optimized Core of the ordinary worker, which contains no source or reason constructor | No regression. The ordinary continuation ignores its lazy argument; snapshot reads, seed scheduling and metrics are unchanged; the `fmap` over the full-replay branch is `fmap id` after inlining and simplifies away |
| Process-manager dispatch (`runProcessManagerOnce`, `advanceDomainProcessManager`) | Unreleased: `managerCommandOptions` adds bounded provenance metadata only under `CaptureInspectionProvenance` | Source: the `NoInspectionProvenance` branch returns the pre-existing `options & #eventIds .~ [managerEventId]`, the helper is `INLINE`, and both `defaultRunCommandOptions` and `inspectionRunCommandOptions` disable capture | Zero cost when disabled. Enabled, it costs one JSON encode per reaction, capped at 64 targets, 64 timer ids and 16 KiB |
| Workflow writer (`keiro_workflows`, steps, children, awakeables, timers) | Unreleased: classification moved into read predicates after the stored class column and two indexes (migrations 0033 and 0034) were withdrawn in 5893c7eb | `readside-writer-capacity`: five saturation pairs, median throughput -1.664%, p95 -1.702%, writer-thread allocation -0.010%; `final-core-interference`: five blocks, six modes, worst median throughput -0.12%; `composed-writer-capacity-final`: the withdrawn DDL cost -9.22% throughput and +12.91% p95 | No regression at HEAD. `keiro-migrations/migrations`, `migrations.native.lock` and the expected-schema snapshot are byte-identical to 0.21.0.0 and to 0.19.0.1 |
| Subscription shard workers (`Keiro.Subscription.Shard`, `Shard.Worker`) | 0.20.0.0: `ensureShards` takes a per-subscription advisory transaction lock and refuses a count mismatch before inserting; `startReader` validates Kiroku's size, group, batch and buffer constructors; `runShardedSubscriptionGroupAck` validates options first | Source: every change is on startup or the once-per-reader claim path; `claimShardsTx`, `renewLeaseTx` and the per-event `handleItem` are unchanged. Kiroku's constructors accept exactly the ranges `mkShardedWorkerOptions` already enforces (`>= 1`, `shardCount <= maxBound :: Int32`), so no valid configuration can fail later inside a reader | No per-event change |
| Catalog command path (`Keiro.Projection`) | 0.20.0.0: `applyCatalogProjectionsTx` delegates to the new `deliverCatalogProjectionsTx`; the guarded runner is additive | Source: group-major, handler-major, event-major delivery and the fence outcomes are unchanged; the precondition callback is reached only through `runDomainCommandWithCatalogProjectionsGuarded` | No change for existing call sites. The changelog records that the owner deferred the exhaustive guarded-catalog performance matrix; the retained partial measurements are not a pass and this review does not treat them as one |
| Outbox, inbox, routers, PGMQ consumption | None in any window (`Keiro.Router` and `Keiro.ProcessManager` changed Haddock only in 0.20.0.0; `keiro-pgmq` changed one blank line) | `git diff --stat` per window | Unchanged |
| Event-store substrate (`kiroku-store` 0.9 to 0.11, migrations 0.6 to 0.7.1, adapter 0.5.1.5 to 0.6.0.1) | 0.20.0.0: the hardening and inspection cohorts; Kiroku migration 0015 adds `ix_streams_browse_name` on `kiroku.streams`, which every new-stream insert and non-HOT application-stream update now maintains | `keiro/bench/results/mp12-kiroku-adoption` retains builds, test journals and formatting logs only; its README says no performance experiment was run because no Keiro append SQL changed. The committed `keiro/bench/baseline-*.csv` rows predate the cohort (2026-07-01 to 2026-09-17) | **The command guard is red at HEAD, and was already red at 0.19.0.1.** Run fresh for this review, the committed `-p command` guard fails 10 of 15 scenarios against its August baseline, the append-heavy ones by 25% to 239%, while every no-append and read-side guard is 27% to 90% faster; rebuilt at the 0.19.0.1 tag it fails nine of 15 with the same shape. Details and attribution below |
| Generated services (`keiro-dsl` 0.21.0.0 templates) | Contract scalar lists, mapped register construction with `write-lift`, whole-name stems, witness-backed harnesses | Delegated reading of every `Scaffold.hs` template hunk: for a service that uses neither lists nor lifts, every emitted-code delta is conditional on `hasListFields`, lift obligations, construction writes or witness entries; the scalar contract codec arms, `payloadIsUsed`, the transducer import plan and the binding-skeleton import predicate emit byte-identical output. The one unconditional change is the `BehaviorContract` refactor, a conformance-support module that no runtime decode, fold, command or publish path calls | No runtime cost for existing services |
| Schema verification (`Keiro.Migrations.SchemaCheck`) | 0.21.0.0: registry lookup for Keiro-managed binding views; unreleased: the comparison runs in PostgreSQL and returns only differences | Callers are `keiro-ops` (once per command) and `keiro-ops-http` (once per admitted request, per websocket upgrade and per feed refresh); the `keiro` runtime library never calls it. `schema-cost-shared` attributes about 10.3 KB of allocation per verification once prepared-statement sharing is preserved | Not on the runtime hot path; its per-refresh use on feeds is a finding below |

The retained evidence covers the unreleased increment well and the 0.20.0.0
substrate change not at all, so the six `just bench-regression` guards were run
twice at the reviewed commit: once while the delegated reviewers were still
running (load average 2.3 to 4.2) and once on the quiet machine (load average
about 2.0, 11:42Z to 11:53Z, no other compiler or test). The second run is the
one reported; the first agreed on every verdict.

| Guard | Result at HEAD |
| --- | --- |
| `producer-identity` (10% same-process ceiling) | **Fails.** `legacy-fresh-1000` 42.4 ms ± 0.6 ms against `deterministic-fresh-1000` 47.2 ms ± 0.9 ms, 1.11x (first run 42.6 against 47.6 ms, 1.12x). `deterministic-single-tx-per-event-1000` 63.3 ms against legacy 67.0 ms, 0.95x, passes. `derive-v1` 531 ns. The retained evidence recorded 84.3 against 87.0 ms (+3.22%); both absolute times have halved, the ratio has not held |
| `outbox` (25% against `baseline-outbox.csv`) | Passes. `hot-key` 485 ms, `hot-key-nolatency` 358 ms, `multi-key` 325 ms: 28% to 41% faster than baseline |
| `inbox` (25% against `baseline-inbox.csv`) | **Fails one of 49.** `table-downstream-single.fresh.metrics-off`, the first fresh downstream scenario the process executes, 5.82 s ± 1.72 s against a 719 ms baseline (710% more); its `metrics-on` twin, run second, 418 ms (39% less). The four historical rows are 39% to 45% faster. This is the position effect REV-17 recorded; af37b955 added a warm-up and re-recorded the baseline from five serial runs (655 to 743 ms), and the first scenario still absorbs a multi-second, high-variance first-run cost |
| `command` (25% against `baseline-command.csv`, recorded 2026-08-11 at 2477a5aa) | **Fails ten of 15.** `control.accepted-1` 3.71 ms (+27%), `domain.accepted-1` 3.92 ms (+25%), `legacy.accepted-large` 41.6 ms (+61%), `domain.accepted-large` 44.2 ms (+48%), `router-fanout` 10 / 100 / 1,000 targets 108 ms / 678 ms / 2.01 s (+231% / +99% / +219%), `process-manager-fanout` 10 / 100 / 1,000 20.0 ms / 177 ms / 1.96 s (+192% / +194% / +239%). `legacy.accepted-1` is the same as baseline and `domain-warmup.accepted-1` +17% passes. `legacy.no-op`, `domain.rejected` and `domain.no-op` are 75 µs, 90% less than baseline |
| `projection` (25%) | Passes. All five scenarios 51% to 56% faster |
| `read-model` (25%) | Passes. Every scenario 27% to 46% faster or the same |

The command result is the one that matters for this review's question. Its
shape is specific: every scenario that appends is slower and every scenario
that only hydrates and decides is an order of magnitude faster. Each command
scenario's timed action hard-deletes its target stream, re-creates it and
appends; the fan-out scenarios dispatch to 10, 100 or 1,000 target streams per
iteration. No Keiro append, stream-lifecycle or dispatch SQL changed between
0.19.0.1 and HEAD (the only per-event code on those paths is untouched, see
the table above), so the slowdown lives in the substrate the 0.20.0.0 cohort
replaced or in the gap between the August baseline and 0.19.0.1, which
adopted Kiroku 0.9 and its category index. To attribute it, the same guard
was built and run from a detached worktree at `keiro-0.19.0.1`: it fails
there too, nine of 15, with the same shape (`accepted-1` +23% to +25%,
`accepted-large` +31% to +53%, router fan-out +63% to +195%,
process-manager fan-out +179% to +252%, no-op and rejected 90% less). Most
of the regression against the August baseline therefore predates the three
reviewed windows. A paired protocol (router fan-out and `accepted-large`
only, two alternating rounds per tree) found HEAD slower than 0.19.0.1 by
12 to 40 ms per iteration on router fan-out at 10 and 100 targets in all
four comparisons, flat at 1,000 targets and on `accepted-large`, while
0.19.0.1 pays about 28 ms more than HEAD in whichever scenario runs first;
that data cannot separate a small in-window per-iteration cost from a
shifted one-time warm-up, and only a bisection across the 0.20.0.0 cohort
commit (2c3a5389, a0a2bd81) with the same paired protocol can. What is
settled is that the committed command guard has been red since before
0.19.0.1 and that nobody ran it: REV-17 ran only the producer, outbox and
inbox guards, and `just bench-regression` is not part of `just verify`.

The producer guard's failure is a relative one: the deterministic producer
path, unchanged since 0.17.0.0, costs about 4.8 ms more per 1,000 rows than
the legacy path where the retained evidence measured 2.7 ms, while both paths
run in about half the absolute time they did then. The deterministic enqueue
issues two statements per row (the `ON CONFLICT DO NOTHING` insert and the
locked read through both unique keys) where the legacy path issues one, so a
substrate whose per-transaction cost fell faster than its per-statement cost
moves the ratio without moving the code. It is reproducible (1.12x, 1.11x) and
the ceiling is the committed gate, so it has to be investigated or
re-justified rather than waved through.

Three read-side costs are new rather than regressions. They do not touch the
writer, but each scales with ledger size rather than page size, and the
unreleased HTTP surface is about to make their behaviour public contract:

| Read | Cost at 100,000 rows (retained plans) | Why |
| --- | ---: | --- |
| `wf inspect list`, default order, first page | 15.2 ms, two sequential scans and one parallel scan plus sort over all 100,002 rows | See the first finding: the wide-key branches scan every `running` and `retrying` row, and the `(workflow_name, workflow_id)` order cannot use the `(workflow_id, workflow_name)` primary key |
| `wf inspect list --ordering created_desc`, first page | 26.9 ms, scan and sort | No index on `created_at`; the evidence README records creation and update-window reads as manual |
| `timer pending list` without filters, and `pm show` (which filters pending timers by manager and correlation) | 0.038 to 15.8 ms | `keiro_timers_due_idx` is `(status, fire_at, process_manager_name)`, so a two-status read or a manager filter scans and sorts the pending set; the drafted edge bounds automatic refresh to one start per five seconds in the measured 100,000-row envelope |

The projection-status page is the counterexample that shows the pattern the
others should follow: selecting a bounded set of group keys first and joining
the frozen v1 relation through `OFFSET 0` took the 100,000-group first page
from 199.6 ms to 2.8 ms with no schema change.

## Required before tagging the next release

1. **Put the release surface in the tree and reconcile it.** Plan 303 names
   0.22.0.0 and a prepared patch outside the repository
   (`/tmp/keiro-mp45-release-review/release.patch`) holds the eight version
   bumps, the `0.21.0.0 -> 0.22.0.0` edge, the blueprint and registry bump to
   0.11.0 and the README and cohort rows; none of it is committed. The drafted
   edge text is accurate about `AppHooks`, `RunCommandOptions`,
   `InspectionFailed`, the `pgmq dlq read` reclassification and the absence of
   reaction provenance; keep it. Before applying the bump, fix the release
   skill's internal-dependency scan: its regex
   `keiro-core|keiro-migrations|keiro-pgmq|keiro-test-support|(^|[ ,])keiro([ ,]|$)`
   does not match `keiro-ops`, so the five `keiro-ops ^>=0.21.0.0` bounds in
   `keiro-ops-http.cabal` and the one in `jitsurei.cabal` would be missed by
   anyone following it literally. The 0.17.0.0 review's warning about blind
   replacement still applies: `shibuya-pgmq-adapter` is at `^>=0.16.1.0` and
   `kiroku-store` at `^>=0.11.0.0`, neither coincides with 0.21.0.0, so this
   bump is safe to do by reading the matches.
2. **Normalize and complete the changelogs.** The release skill requires
   exactly Breaking Changes, New Features, Bug Fixes and Other Changes.
   The root `CHANGELOG.md` Unreleased section opens with four bullets under no
   heading and uses a `### Performance` heading; `keiro-migrations/CHANGELOG.md`
   has an empty `### New Features` and a `### Added`; `keiro-ops/CHANGELOG.md`
   has `### Changed` and `### Added`; `keiro-ops-http/CHANGELOG.md` has
   `### Added`. Entries missing from the root changelog that the package
   changelogs or the code carry: `pgmq dlq read` is now a mutation on the CLI
   (a non-forced read exits 1 with a preview); `OpsOutcome` gains the
   `InspectionFailed` constructor (`keiro-ops/src/Keiro/Ops/Render.hs:37`),
   which breaks exhaustive matches in every embedder and appears in no
   changelog at all; `wf list` and `wf show` JSON gain `status_class`, `wf
   steps` entries gain `recorded_at`, `wf show` now orders awakeables by
   `(created_at, awakeable_id)` and children by `(created_at, child_id,
   child_name)` from the owner tables, `wf show/steps/journal` return
   `InspectionFailed` where they returned `Failed` text, and `shard status`
   gains `observed_at`, `heartbeat_at`, `updated_at` and `lease_age_seconds`;
   `Keiro.Migrations.SchemaCheck.verifyExpectedSchemaSession` is only in the
   package changelog. `RunCommandOptions.inspectionProvenance` and the
   `AppHooks` fields are record-construction breaks and belong under Breaking
   Changes rather than New Features.
3. **Decide the workflow listing's cost model before its cursor contract
   ships.** See the first finding. The cheapest correct change is to order the
   default page by the primary key's own column order so the first page and
   every continuation become an index range scan, and to drop the wide-key
   union now that no index excludes wide tuples. If the owner prefers to keep
   the `(workflow_name, workflow_id)` order, a matching index is the only way
   to make it sublinear, and the writer-capacity gate must be rerun with it. If
   neither, document the ledger-wide cost per page in `docs/user/durable-workflows.md`
   and the serve guide as the operating envelope, the way the pending-timer
   edge text already does for timers. Either way, delete the vestigial split or
   explain why it stays; the evidence README's claim that the reads use
   "existing key/status indexes" is not true for the default order.
4. **Gate confirmed mutations by origin.** `corsMiddleware` only adds response
   headers for allow-listed origins and never refuses a request; the POST path
   reads the body and compares it with `{"confirm":"execute"}` without looking
   at `Origin`, `Sec-Fetch-Site` or `Content-Type`. A cross-site
   `fetch(url, {method: "POST", mode: "no-cors", body: '{"confirm":"execute"}'})`
   sends `text/plain` without a preflight and is executed. Websocket upgrades
   do enforce the allow-list, so the policy is asymmetric. Refuse a mutation
   whose `Origin` is present and not allow-listed or same-origin, and require
   `Content-Type: application/json` for a non-empty body. This matters as soon
   as the surface sits behind a cookie-authenticating proxy with
   `--enable-mutations`.
5. **Label or extend process-manager inspection for the 1.0 direction.**
   `Keiro.ProcessManager.Inspect` constructs inspectors only from
   `ProcessManager` and `DomainProcessManager`; `Keiro.ProcessManager.Reaction`
   has no inspector, no provenance family and no capture hook, and the drafted
   edge says "Modern reaction provenance is unavailable". Plan 304 retires the
   positional API with Languages 1 to 5. Either add a `ReactiveProcessManager`
   inspector before publication or mark `pm show`, `pm list`,
   `inspectionProvenance` and the `legacy-positional-v1` family as legacy-only
   in the changelog, the user guide and the edge, so their removal in the
   retirement release is announced now rather than discovered then.
6. **Fix the stale user documentation lines.** `docs/user/operations.md:147`
   still says "`read` is read-only and decodes visible entries" two lines
   below a console block that shows `--force`; the stream guide lists only
   three of the eight websocket error codes in `Protocol.hs` (`invalid_frame`,
   `unknown_feed`, `invalid_subscription`, `too_many_views` and
   `inspection_busy` are missing), and the serve guide's error table omits the
   mutation `exit_code` body field, the 409 `cursor_generation_mismatch` and
   the 400 codes `invalid_cursor`, `invalid_page_size` and
   `inspection_header_inconsistent`.
7. **Amend the published-language regeneration scope.** 0.21.0.0 is on
   Hackage and cannot change, but its edge prompt and the `keiro-dsl`
   changelog understate what a consumer sees on regeneration; see the
   keiro-dsl section. Correct `0.20.0.0-to-0.21.0.0.md` (edges are
   append-only, their text is not) and carry the correction into the 0.22
   edge so a consumer crossing both windows is told once that every
   aggregate's `BehaviorContract.hs` changes.
8. **Make the performance guards green again, with evidence, before the
   tag.** `just bench-regression` is red at HEAD on three of its six guards
   (see Hot-path performance). The command guard needs attribution first:
   bisect the append-path slowdown between the August baseline, 0.19.0.0
   (Kiroku 0.9), 0.20.0.0 (Kiroku 0.11) and HEAD, and either fix the cause or
   record a new baseline with a README that states what the substrate now
   costs and why that is accepted; do not re-record it merely because it
   fails. The producer guard needs the same decision for its 10% ceiling. The
   inbox guard needs its first fresh scenario made robust (a second warm-up, a
   throwaway first scenario, or exclusion of the first-run cost from the timed
   action), which REV-17 already asked for. `just bench-regression` is not in
   `just verify`, so nothing in the release gate catches any of this; add it,
   or add a recorded run to the release checklist.

## Findings

- **The default workflow listing scans the whole ledger on every page, and
  half of that work is vestigial.** `inspectionInstanceStatement` in
  `keiro/src/Keiro/Workflow/Instance.hs` splits every list into a narrow page
  (keys up to `maxIndexedWorkflowKeyBytes = 2600` bytes) and a wide union of
  seven per-class branches, each `LIMIT 65`, whose candidates are budgeted
  before merging. The constants are named for the inspection indexes that were
  to exclude oversized tuples (`key-domain` evidence), but 5893c7eb withdrew
  those indexes and kept the split. With only the published indexes, the
  retained plan for the default first page at 100,000 rows
  (`query-readside/100000-force_custom_plan-key-first.json`) shows the
  `running` and `retrying` wide branches as sequential scans that remove
  100,001 and 100,002 rows by filter, the five terminal-class branches as
  `keiro_workflows_gc_idx` scans, and the narrow page itself as a parallel
  sequential scan plus top-N sort, because `ORDER BY workflow_name,
  workflow_id` cannot be served by `keiro_workflows_pkey (workflow_id,
  workflow_name)`. Total 15.2 ms at 100,000 rows and linear beyond it; the
  deep-cursor page is 12.6 ms for the same reason. The pre-existing
  `listWorkflowInstances` has the same order and cursor and so the same
  mismatch; the new API inherits it and adds the seven branches. The
  `InspectionWorkLimitExceeded` refusal for more than 64 wide keys is correct
  as written and is tested at 100,000 wide rows, but it now protects against a
  population that no index would have excluded anyway. (correctness: none;
  performance and design: medium; becomes contract at 0.22)
- **Slow readers can hold every inspection permit, including the one
  `/health` needs.** `withInspectionAdmission` holds the permit through
  `respond` by design (Budget.hs, "so slow clients cannot retain an unbounded
  number of encoded response bodies"), while `withInspectionDeadline` bounds
  only the computation. Warp's inactivity timer is tickled on every sent
  chunk, so a client that drains one TCP window per timeout period keeps its
  permit indefinitely. With the default `maxConcurrentReads` of four, four
  such clients requesting a 1 MiB page make every HTTP read, every mutation,
  every websocket upgrade and every feed refresh answer `inspection_busy`.
  The trade-off is deliberate; the fix is a delivery deadline around
  `respond` or a separate, smaller delivery-only permit. (operability: medium;
  verified in code, exploit plausible)
- **Every feed refresh re-verifies the schema.** `readView` calls
  `checkFeedSchema`, which runs the three-statement verification including the
  `pg_catalog` snapshot joined against the embedded expected `VALUES`, on each
  refresh of each view; drivers refresh on notify at a one-second cadence
  (five seconds for timers). Thirty-two active views can issue around thirty
  verifications a second, each taking an inspection permit that operators
  share. One verification per handle per fallback tick would preserve the
  drift guarantee. (performance: medium-low)
- **0.21.0.0 regenerated published-language output beyond its stated scope.**
  Verified by this reviewer: `git diff keiro-0.20.0.0..keiro-0.21.0.0 --
  'keiro-dsl/test/**BehaviorContract.hs'` touches 47 files with 2,079
  insertions, and the non-provenance hunks (export of
  `behaviorObligationReport`, `behaviorCoverageReport = coverageReportFor
  behaviorRequirements`, the new `coverageReportFor`) appear in Language 3, 4
  and 5 corpora such as `conformance-id-domain-migration` and
  `conformance/.../Reservation/BehaviorContract.hs`. The witness-backed harness
  change is gated on `ExplicitTransitionImplementationSyntax`, which Language
  2 and later carry, and the new `conformance-service-package/domain/assignment.keiro`
  that proves it declares `language keiro-dsl 4`. Fold fingerprints and
  snapshot identity are unchanged, so no replay identity moved, and the corpus
  policy accepted the regeneration, but the edge text's "regenerate aggregate
  BehaviorContract and harness modules for hole-owned live initial
  transitions" describes a subset of what every consumer's `keiro-dsl
  scaffold` will rewrite. (documentation: medium; design note for 1.0 below)
- **`keiro-dsl` 0.21.0.0 Breaking Changes omit public API changes.**
  `Keiro.Dsl.Expression.TypedScalarNode` gains `TypedMappedLift` and
  `TypedMappedInitial`; `ExpressionDiagnosticCode` gains four constructors;
  `LanguageFeature` gains two; `TypeGraph.MappedDeclError` gains
  `InvalidMappedWriteLift`; `DiagnosticCode`, which derives `Enum` and
  `Bounded`, gains eight constructors in the middle of its order, so `fromEnum`
  positions after `ContractTypeIdDomainChanged` and `AggGuardRemedyUnavailable`
  shift; the `MappingIdentity` ledger JSON gains an optional `writeLift` key;
  `Scaffold.behaviorRequirementsFor` is newly exported and calls `error` on a
  derivation failure; and `ScaffoldRun.pureRefusalsForService` gains a new
  pre-write refusal class from `generatedImportResolutionViolations`. None is
  in the changelog or the edge. (documentation: low)
- **Cross-language id-domain diffs reclassify.** `Diff.hs` now requires both
  revisions to carry a resolved admission before taking the rebuild-advisory
  path, so a same-prefix literal-to-declared transition whose old revision
  predates `ContractIdDomainTypeIdV7` (Languages 1 to 3) is now `breaking`
  rather than an advisory. Arguably right, undocumented, and moot once those
  languages retire. (design: low; plausible)
- **A retiring feed view answers `inspection_busy`.** An entry with zero
  references that is waiting for its driver to join refuses a new subscriber
  with `FeedBusy`, so a quick unsubscribe and resubscribe of the same filters
  reports capacity exhaustion although capacity is free. (operability: low)
- **Feed snapshots are re-encoded on every refresh** even when nothing changed
  (`prepare (P.Snapshot ...)` runs unconditionally in `refresh`), up to 1 MiB
  of JSON per view per second. (performance: low)
- **Same-origin websocket fallback breaks behind TLS termination.** The
  computed origin uses `isSecure`, so `https://host` never matches
  `http://host` on a plain listener behind a TLS proxy; operators must
  allow-list explicitly. HTTP CORS compares origins case-sensitively while the
  websocket path lowercases. (documentation: low)
- **Confirmation is replayable.** `{"confirm":"execute"}` carries no nonce or
  idempotency key, so a proxy that retries a 504 `mutation_outcome_unknown`
  re-executes. The serve guide documents "inspect before retrying", so this is
  design rather than defect. (operability: low)
- **The standalone executable opens a second, unused store pool** before
  `withOpsInspectionPool` replaces it; Kiroku's publisher issues one statement
  on it at startup and the notifier holds a `LISTEN` connection. The comment
  "This store belongs only to inspection" overstates. (operability: info)
- **`jitsurei`'s aggregate catalog is a panicking CAF**
  (`either (error ...) id`), failing at first use rather than startup.
  Acceptable for an example. (info)

## What was examined and found sound

### 0.19.0.1 to 0.20.0.0 (32 commits)

- **Kiroku 0.11 cohort adoption** (`a0a2bd81`, `2c3a5389`). Every
  `kiroku-store` bound moved from `>=0.9.0.1 && <0.10` to `^>=0.11.0.0`,
  `kiroku-store-migrations` to `^>=0.7.1.0`, `shibuya-kiroku-adapter` to
  `^>=0.6.0.1`, `shibuya-core` to `^>=0.10.0.1` and the five pgmq packages to
  `>=0.6.1.1 && <0.7`. Hackage serves every one of those versions (and
  `kiroku-store` 0.11.0.1, which the caret bound admits). The new
  `EventDecodeFailed` store error is classified non-transient, so a poisoned
  event dead-letters instead of retrying forever. `ShardCountMismatch` joins
  Kiroku's `SomeSubscriptionStartupFailure` family through a hand-written
  `Exception` instance whose `fromException` unwraps the parent and casts, so
  a direct typed catch still works, and `startReader` relinquishes its bucket
  and reports `ShardReaderStartupFailed` when Kiroku refuses a topology.
- **Atomic shard resize** (`resizeShardCountTx`). The transaction takes the
  per-subscription advisory key, then every lease row `FOR UPDATE` in bucket
  order, refuses on any recorded owner including an expired one, and only then
  calls Kiroku's released `resizeConsumerGroupTx` and replaces the lease rows;
  a refusal performs no write. `ensureShards` takes the same advisory key
  first, so a concurrent startup and resize serialize instead of interleaving
  `ON CONFLICT DO NOTHING` inserts with the delete.
- **Guarded catalog commands**. `runDomainCommandWithCatalogProjectionsGuarded`
  reuses `runDomainCommandWithSqlEventsControlled`; the precondition runs with
  the group fence held and before delivery, a `Left` rolls back the whole
  append, and silent domain decisions never reach the callback. The Haddock
  states the trust boundary (bounded transaction-local SQL, no savepoints,
  locks or recursive appends) and that the store-wide append lock is what makes
  the identity check atomic. `GuardedCatalogOutcome` keeps every existing
  outcome type intact.
- **Test support**. `withMigratedBenchmarkSuite` enables durable settings on
  a local server or takes an operator-supplied libpq keyword string, creates a
  uniquely named template and drops only databases it created; the resource
  fixtures became polymorphic in their result without changing callers.
- **Upgrade edge**. `0.19.0.1-to-0.20.0.0.md` names the bounds, the
  `ShardWorkerError` constructor, the exception family change, the 44 to 47
  composed-plan growth, the resize procedure and the provenance restamp, and
  entails `kiroku-upgrade` `0.9.0.1 -> 0.10.0.0` and `0.10.0.0 -> 0.11.0.0`;
  both entailed edges exist in the Kiroku blueprint on `origin/master`.

### 0.20.0.0 to 0.21.0.0 (55 commits)

- **Registry-aware schema verification** (BUG-12, `b13d814d`).
  `managedObjectSnapshotKeys` resolves `keiro.keiro_managed_read_objects`
  through `pg_class`, so a missing table or a role without `SELECT` and
  `USAGE` yields the empty set and the catalog-only comparison, exactly as
  before; only `binding-view` rows map to a snapshot key, and a managed key is
  excused only from `UnexpectedObject`, never from a missing or changed
  migration object. `compareSchemaSnapshot` is preserved as the empty-set case.
- **keiro-dsl**. The four fixes and two features are correct and pinned; see
  the keiro-dsl section.
- **Upgrade edge**. `0.20.0.0-to-0.21.0.0.md` exists and entails nothing,
  which is correct because the upstream cohort did not move.

### 0.21.0.0 to HEAD (19 commits, unreleased)

- **Command hydration and inspection options**. `inspectionRunCommandOptions`
  disables seed verification, metrics, tracing and post-append replay
  verification; `hydrateWithSource` is the only constructor of a
  `HydrationSource`. `RunCommandOptions` gains the strict
  `inspectionProvenance` field defaulting to `NoInspectionProvenance`, a
  record-construction break the changelog and the drafted edge both state.
- **Provenance encoding** (`Keiro.ProcessManager.Provenance`). Only the
  `legacy-positional-v1` family encodes; the prefix walk takes at most 64
  targets and 64 timer ids, a single target name above 16 KiB or an encoded
  frame above 16 KiB collapses to a source-only frame with `truncated = true`,
  and decoding rejects unknown versions, other families, oversized frames,
  negative emit indices and arrays above the bound. `withProvenanceMetadata`
  leaves a non-object caller metadata value intact so the existing codec
  rejection still fires.
- **Workflow instance reads** (`Keiro.Workflow.Instance`). The ordinary
  `lookupInstanceStmt` and `instanceRowDecoder` are unchanged in behaviour;
  the decoder is now built through `instanceFields`, a rank-2 helper shared
  with the nullable outer-join row, and both remain top-level values so the
  decoder is constructed once. `lookupInstanceConditionalSession` compares the
  complete header image in PostgreSQL (`value = $1::jsonb`, semantic equality),
  bounds the image bytes before decoding, and keeps missing, changed and
  oversized rows distinct; the timestamp image splits days from seconds so
  distant and BC dates round-trip, and the infinity sentinels match the
  binary decoder's `Int64` interpretation. The `WorkflowHeaderCache` in
  `keiro-ops` refuses entries above 1 MiB, evicts FIFO to stay under 32 entries
  and 1 MiB, executes the `SELECT` on every lookup, and never serves a changed,
  missing or oversized row from memory; the CLI never uses it.
- **Bounded inspection pages**. Every page read validates size (1 to 500) and
  decodes its cursor before borrowing a connection; cursors are base64url JSON
  bound to a kind and, for detail pages, to the owning workflow and
  generation; `encodeCursorBounded` refuses to emit a continuation the decoder
  would reject (the "cursor the next request cannot decode" fix); step, child
  and awakeable pages use the existing `keiro_workflow_steps_pkey`,
  `keiro_workflow_children_parent_idx` and `keiro_awakeables_owner_idx`
  orders; projection-status pages select a bounded set of group keys first
  and join the frozen v1 relation through `OFFSET 0`; pending-timer pages read
  in `(fire_at, timer_id)` order with both optional filters bound into the
  cursor; shard views are observational and acquire nothing.
- **Aggregate and process-manager inspection**. `aggregateStream` and
  `aggregateIdOf` require that `mkStream`, `resolveStreamName` and the
  category prefix name the same physical stream before any read, so an audit
  target that maps a physical name to a different typed handle cannot be
  inspected under the wrong identity. Deleted streams skip hydration.
  `inspectProcessManagerInstance` reads one head event for the last reaction,
  probes at most the 64 recorded dispatch targets with `firstExistingEventId`,
  and reports absence as `NotObserved` rather than failure.
- **Schema comparison in PostgreSQL**. The expected snapshot is embedded once
  per connection as a `VALUES` list of `E'...'` literals with backslashes and
  quotes escaped; the live side reproduces `Map.fromList` over the two sorted
  schemas with `DISTINCT ON (key) ... ORDER BY key, priority DESC, line DESC`
  (public schema wins, then the last C-sorted line); the `FULL JOIN` returns
  exactly the missing, unexpected-and-unmanaged and changed rows, and the
  decoder's `error` arm is unreachable because every returned row has either
  one non-null line or both lines with non-null definitions. The multiline
  fix JSON-quotes generated expressions and escapes backslash, LF and CR in
  defaults so the stored snapshot stays one line per object.
- **HTTP transport resource bounds** (re-verified from the delegated
  reading). Per-connection outgoing queues drop oldest pending frames to stay
  under 256 frames and 2 MiB, an in-flight frame stays charged until the
  writer finishes it inside `bracket`, every frame is prepared at the
  smaller of the frame and queue caps so it always fits an empty queue, and
  overflow error frames are pre-built. An idle socket holds a connection slot
  and threads but no permit and no pool connection; drivers take a permit only
  inside `bounded` and a pool connection only inside that. There is one driver
  per canonical view and one wake pump per handle, refresh cadence is floored
  at the configured minimum and runs only while subscribers exist, slow
  clients hit `boundedSend`'s timeout and are cleaned up, and server shutdown
  cancels the Warp worker, stops drivers, cancels the pump and waits for the
  connection count to reach zero. The 88b56fc1 fix forces the connection
  registry map on every update (`pure $!`), which is the one registry nothing
  read between updates; the sibling lazy-return sites are each forced by the
  next operation's read. Method is derived from `isMutation` and checked
  before execution, `force = mutation && confirmed`, confirmation is exact
  object equality against a body of at most 1 KiB, `pgmq dlq read` is a
  mutation on both CLI and HTTP, CORS echoes exact origins only with no
  credentials, and `stripSurfacePrefix` drops exactly one raw segment only
  when the raw path decodes to the parsed segments.
- **Library dependency surface**. The `keiro` library gains only
  `base64-bytestring` and seven modules; `keiro-ops-http` is the only package
  depending on `wai`, `warp`, `wai-websockets` and `websockets`, so a consumer
  that does not mount inspection pulls no web stack. `cabal check` reports no
  errors or warnings in all eight package directories; the `compose-example`
  flag is manual and default-off, and `kiroku-metrics` 0.3.0.1, `hasql-pool`
  1.4.2.3 and `pgmq-migration` 0.6.1.1 satisfy the declared bounds on Hackage.
- **jitsurei**. The example wires aggregate and process-manager inspectors
  into `AppHooks`, and its tests drive `inspectAggregate`, `listAggregates`,
  `inspectProcessManagerInstance` and the embedded `aggregate show` and
  `pm show/list` commands end to end against the fulfillment manager with
  provenance capture enabled.

## keiro-dsl 0.21.0.0

The increment was read in full by a delegated reviewer (about 3,600 diff
lines across 32 source modules) against the changelog, the blueprint edge,
the corpora and the language registry; the findings above that bear on the
verdict were re-verified by this reviewer in the corpus diff.

Sound:

- **BUG-10.** `initialWitnessProbeEntries` routes hole-owned initial edges to
  `witnessAcceptDecl` and `witnessForwardReplayDecl`; the emitted acceptance
  requires exactly one non-pending witness per key and an empty failure list,
  and accept rows for every initial live edge are wired into the harness
  assertions. The one new `error` (`witnessKeyFor`) is unreachable on a
  validated aggregate because ordinals are 0-based, declaration indices are
  1-based and each live transition yields exactly one requirement. Pinned in
  `test/Main.hs`, the compiled `keiro-dsl-conformance-history-dependent-holes`
  suite and the mutation script in `just verify`.
- **BUG-11.** `deriveUpperCamelName` checks only the upper occurrence, so a
  segment whose lowerCamel form is a keyword no longer falls back to the raw
  name; the queue codec stem, outcome type, `readModelStem` (now shared with
  the harness) and `generatedCase` call it. Pinned in `test/haskell-name` and
  the compiled `keiro-dsl-conformance-keyword-segments` suite.
- **IR-50.** `ReplayImpact` no longer builds a mixed graph; each revision
  resolves its own `FoldEvidence`, retained bodies are compared through
  `Map.intersectionWith`, and the canonical segment order equals 0.20.0.0's.
- **Contract parser.** `List` is claimed only when not followed by a field
  boundary; `keyword` is case-sensitive `chunk`, so `list` and `LIST` parse as
  declared ids; `TypeGraph` admits one declared id named `Optional`, `List` or
  `Map` colliding only with the built-in; the breaking classification for
  same-prefix widening requires both admissions to be known. bade340b
  qualifies the `Index` constructor and the conformance suite compiles against
  an event literally named `Index`.
- **Language gating.** `ContractListFieldSyntax` lives only in `profileV5`
  (Language 6); `mapped(` and `write-lift` go through `requireLanguageFeatureAt`;
  Language 5 refusals are pinned for both. List codecs reject non-arrays and
  null elements, preserve order, and require presence; list-valued outbox and
  dedupe keys are refused in `Validate`. Fold identity appends the lift
  provenance only when a lift is used; the totality of a lift is a consumer
  obligation checked per fixture case.
- **Determinism.** New ordering uses `Map`, `Set`, `sortOn` and
  `Set.toAscList`; `nub` appears only inside emitted assertion text; no hashed
  containers.

Findings are recorded under Findings above: the published-language
regeneration scope, the Breaking Changes omissions, and the cross-language
diff reclassification. Two further low notes: the harness drops its unused
opaque-fixtures import for register-only opaque declarations, which changes
Language 1 to 5 harness text for such specs although no corpus exercises it;
and `pascal "type"` now yields `Type` where 0.20.0.0 yielded `type`, which is
harmless because whole-name keywords are refused by `validateNames`.

## The path to 1.0.0.0 and Language 6

The owner's stated direction is 1.0.0.0 within the next few releases with
every DSL language except Language 6 retired; ADR-49 and plan 304 record that
as a staged pre-1.0 breaking release. Read against it, the three increments
carry the following weight:

- **Language 6 is still a candidate at HEAD** (`languageRegistry` lists it as
  `Candidate CandidateLanguage` with Language 5 as the sole `Stable`), and
  0.21.0.0 added three Language 6 constructs without publishing it. Each
  construct widens the surface that must be frozen before Languages 1 to 5
  can be deprecated; the additions are consistent with the goal. The fixture
  census is not yet: at HEAD the repository holds 241 Language 4, 32 Language
  5 and 75 Language 6 fixtures, and the 0.21.0.0 window added one Language 4
  and one Language 5 fixture alongside eleven Language 6 ones. Every legacy
  fixture added now is one plan 304 must migrate or delete.
- **Published languages were not frozen in 0.21.0.0.** The BehaviorContract
  and harness regeneration above is exactly the kind of drift the
  "published languages are immutable" rule exists to prevent. Under the
  retirement plan it does not matter for long, but until that release ships,
  consumers on Languages 4 and 5 should be told the truth in the edge.
- **The reaction template no longer truncates its identity seed.** REV-17's
  finding against the Language 6 candidate is closed: `emitReactionProcessGen`
  derives `reactionIdentity` from length-prefixed UTF-8 fields (plan 285 M1).
  The only remaining `fromEnum`-truncated seed is `namedUuid` in
  `emitProcessGen`, the frozen legacy process template, which retires with
  Languages 1 to 5.
- **The unreleased process-manager inspection targets the API being retired.**
  Required item 5 above. Shipping `pm show`, `pm list` and the
  `legacy-positional-v1` provenance family in 0.22 adds an operator-visible
  contract to the surface plan 304 removes, while the surface that survives
  has none.
- **Deprecated runtime exports are correctly tied to the Language 4
  generator.** `Keiro.ReadModel` carries twelve `DEPRECATED` pragmas (one more
  each in `Keiro.Projection` and `Keiro.Outbox`) whose text now says they are
  removed with the Language 4 read-model generator in a later major release.
  REV-17's note that they promised removal "in 0.13" is resolved.
- **Contracts that 0.22 would freeze.** The inspection cursor codec (`k`/`v`
  envelope, 4,096-byte cap), the seven workflow status classes, the
  `InspectionWorkLimitExceeded` refusal, the page JSON shapes and the HTTP
  routes all become public with the next tag and would be frozen at 1.0.0.0.
  The wide-key finding is the one place where the contract encodes a design
  that has already been withdrawn; settle it before the tag rather than before
  1.0.

## Follow-ups that do not block the tag

- `mori.dhall` declares `effectful` and `effectful-core` at `>=2.6 && <2.7`
  in five places; the cabal files have carried `effectful >=2.6 && <2.8` and
  `effectful-core >=2.6 && <2.7 || >=2.7.1.1 && <2.8` since 0.19.0.1. The
  shibuya-pgmq-adapter entry REV-17 flagged is reconciled.
- `keiro-dsl-runtime-vocabulary-test` and `keiro-dsl-codec-bench` no longer
  carry unbounded internal dependencies outside the conformance stanzas; the
  REV-15 follow-up is closed. `hspec >=2.11` in `keiro-ops-http`'s test suite
  has no upper bound.
- The feed and header-cache improvements listed under Findings as low:
  skip the snapshot re-encode when nothing changed, give a retiring view a
  distinct code, verify the schema once per handle per tick, and note the TLS
  origin caveat in the stream guide.
- The `ReactiveProcessManager` inspector, if the owner chooses to label rather
  than extend before 0.22.
- A `created_at` order index, if creation-order browsing is to become
  automatic rather than manual; the evidence README already records it as
  manual.
- `scripts/inspection-*.hs` (fifteen standalone drivers, 1,734 lines) live
  under `scripts/` with no build stanza, so they rot silently; either
  wire them into a `buildable: False` stanza or move them next to the
  evidence they produced.
- The `cd <package> && nix develop` pattern initializes a PostgreSQL cluster
  under `<package>/db` through the dev-shell hook (`nix/haskell.nix:127-136`
  sets `PGDATA` relative to the working directory). Six such clusters were
  created and removed during this review; `keiro-ops/db` and
  `keiro-ops-http/db`, dated 2026-10-20, predate it and were left alone. The
  release skill's "run `cabal check` from `<pkg-dir>`" step triggers this.

## Evidence

- `git log --oneline keiro-0.19.0.1..HEAD` lists 106 commits (32, 55 and 19
  per window) touching 2,443 files (90,331 insertions, 11,942 deletions);
  per window: 1,301 files (39,236 / 953), 936 files (31,704 / 12,892) and
  1,907 files (42,184 / 952). `origin/master` equals HEAD after `git fetch`.
- `git diff --stat keiro-0.19.0.1..HEAD -- keiro-migrations/migrations
  keiro-migrations/expected-schema keiro-migrations/migrations.native.lock`
  printed nothing; the same is true from `keiro-0.21.0.0`.
- Hackage `preferred` reports `kiroku-store` 0.11.0.1 and 0.11.0.0,
  `kiroku-store-migrations` 0.7.1.0, `shibuya-kiroku-adapter` 0.6.0.1,
  `shibuya-core` 0.10.0.1, `shibuya-pgmq-adapter` 0.16.1.0, the five pgmq
  packages at 0.6.1.1, `kiroku-metrics` 0.3.0.1, and `keiro` and `keiro-ops`
  at 0.21.0.0.
- `cabal check` in all eight package directories: "No errors or warnings
  could be found in the package."
- `nix develop -c cabal build all --enable-tests --enable-benchmarks` at the
  reviewed commit: exit 0, no warnings.
- `nix develop -c just haskell-test` (2026-10-21T11:27:59Z to 11:36:33Z):
  exit 0; 65 suites passed, none failed; `keiro-test` 783 examples,
  `keiro-retention` 15, `keiro-pgmq-test` 80 (2 pending), `keiro-ops-test` 53,
  `keiro-ops-http-test` 40, `keiro-dsl-test` 884, two further hspec suites of
  9 and 25, `jitsurei-test` 25; "All generated jitsurei diagrams are up to
  date."
- `adr-validate`, `research-validate`, `capabilities-validate`,
  `reviews-validate`, `bug-reports-validate`, `user-documentation-validate`,
  `terminology-validate`, `extension-policy`, `dsl-api-boundaries`,
  `keiro-reexports`, `record-migration-policy`, `generated-name-policy` and
  `replay-compatibility`: all exit 0 (11:33:03Z to 11:34:19Z).
  `conformance-corpus-policy`, `jitsurei-verify` (disposable database) and
  `cabal test keiro-migrations-test` (41 examples): exit 0.
  `process-compose-check`: "Validated 3 configured processes from 2 files."
  `nix flake check`: exit 0.
- `mapped-register-construction-proof`, `initial-hole-proof`,
  `checked-mapping-adoption` and `process-reaction-proof` (12:05Z to 12:11Z):
  all exit 0, and `git status --porcelain` afterwards lists only this review's
  three files, so every in-place corpus mutation was restored. Together with
  the suites and policies above, every recipe `just verify` runs passed at the
  reviewed commit, executed individually rather than through the umbrella
  recipe so the benchmark runs could be interleaved.
- `nix develop -c just bench-regression` at the reviewed commit, first run
  11:37:04Z to 11:39:47Z with load average 2.30 (two delegated reviewers
  running): `producer-identity` exited 1 at `deterministic-fresh-1000` 47.6 ms
  against 42.6 ms (1.12x) and the recipe stopped there. Second run, the six
  guard commands from the `bench-regression` recipe executed one by one,
  11:42:06Z to 11:53:02Z, load average 1.99 at start, no other compiler or
  test: `producer-identity` exit 1 (1 of 6), `outbox` exit 0, `inbox` exit 1
  (1 of 49), `command` exit 1 (10 of 15), `projection` exit 0, `read-model`
  exit 0. Full output in the reviewer's scratch logs; the numbers are
  transcribed above.
- `keiro/bench/baseline-command.csv` last changed at 2477a5aa (2026-08-11);
  `baseline-inbox.csv` at af37b955 (2026-09-17), which re-recorded
  `table-downstream-single.fresh.metrics-off` from 1.844 s ± 1.682 s to
  718.7 ms ± 57.9 ms; `baseline-outbox.csv` (2026-07-01),
  `baseline-projection.csv` and `baseline-read-model.csv` (2026-08-14) are
  older than every reviewed window.
- Attribution run: a detached worktree at `keiro-0.19.0.1` (9b215c11) built
  `keiro-bench` from the normal store (exit 0) and ran the same `-p command`
  guard against the same `baseline-command.csv` (11:53Z to 11:58Z, load
  average 1.60 at start): exit 1, 9 of 15 fail: `control.accepted-1` 3.64 ms
  (+25%), `domain.accepted-1` 3.88 ms (+23%), `legacy.accepted-large` 39.5 ms
  (+53%), `domain.accepted-large` 39.4 ms (+31%), `router-fanout` 10 / 100 /
  1,000 79.6 ms / 556 ms / 1.86 s (+143% / +63% / +195%),
  `process-manager-fanout` 10 / 100 / 1,000 19.1 ms / 189 ms / 2.04 s
  (+179% / +215% / +252%); `no-op` and `rejected` 73 to 76 µs (90% less);
  `legacy.accepted-1` same as baseline.
- Paired legs, `-p '/command/&&(/router-fanout/||/accepted-large/)'`,
  alternating 0.19.0.1, HEAD, 0.19.0.1, HEAD (11:58Z to 12:04Z, load average
  1.46 at start): `legacy.accepted-large` 66.1 / 38.0 / 65.8 / 39.7 ms;
  `domain.accepted-large` 37.3 / 37.9 / 37.4 / 40.9 ms; `router-fanout.10`
  64.3 / 76.6 / 60.9 / 103 ms; `router-fanout.100` 516 / 536 / 512 / 646 ms;
  `router-fanout.1000` 5.04 / 5.02 / 5.08 / 5.06 s. The 1,000-target scenario
  measures about 5.0 s under this filter and 1.9 to 2.0 s inside the full
  guard on both trees, so absolute values compare only within one filter and
  order. The worktree was removed after the run.
- Retained plan `query-readside/100000-force_custom_plan-key-first.json`:
  execution 15.225 ms; `Seq Scan keiro_workflows ... Rows Removed by Filter:
  100001` and `100002` for the `running` and `retrying` wide branches; five
  `Index Scan keiro_workflows_gc_idx` for the terminal classes; `Gather Merge
  -> Sort -> Seq Scan` (50,000 rows per worker, filter `octet_length(...) <=
  2600`) for the narrow page. `keiro-v18.txt:655` defines
  `keiro_workflows_pkey ON keiro.keiro_workflows USING btree (workflow_id,
  workflow_name)`.
- `git diff --stat keiro-0.20.0.0..keiro-0.21.0.0 -- 'keiro-dsl/test/**BehaviorContract.hs'`:
  47 files changed, 2,079 insertions, 132 deletions. `git show
  keiro-0.21.0.0:keiro-dsl/test/conformance-service-package/domain/assignment.keiro`
  opens with `language keiro-dsl 4`.
- `grep -rn InspectionFailed CHANGELOG.md keiro-ops/CHANGELOG.md` printed
  nothing; `keiro-ops/src/Keiro/Ops/Render.hs:37` adds the constructor.
- The release skill regex, applied to `keiro-ops-http` and `jitsurei`, matches
  the `keiro`, `keiro-migrations`, `keiro-pgmq` and `keiro-test-support`
  bounds and misses `keiro-ops ^>=0.21.0.0` at `keiro-ops-http.cabal:83,110,135,167,207`
  and `jitsurei.cabal:166`.
- Kiroku blueprint on `origin/master` declares edges `0.9.0.1 -> 0.10.0.0`
  and `0.10.0.0 -> 0.11.0.0`, matching the Keiro 0.20.0.0 edge's `entails`.
- `/tmp/keiro-mp45-release-review/release.patch` (outside the repository,
  referenced by plan 303) contains the 0.22.0.0 edge, the blueprint and
  registry bump to 0.11.0, the README row and the cohort row; nothing in it
  is in the tree.
