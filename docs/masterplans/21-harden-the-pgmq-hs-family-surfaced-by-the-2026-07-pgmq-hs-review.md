---
id: 21
slug: harden-the-pgmq-hs-family-surfaced-by-the-2026-07-pgmq-hs-review
title: "Harden the pgmq-hs family surfaced by the 2026-07 pgmq-hs review"
kind: master-plan
created_at: 2026-07-23T04:18:29Z
---

# Superseded: Harden the pgmq-hs family surfaced by the 2026-07 pgmq-hs review

This MasterPlan's pgmq-hs implementation scope is superseded and must not be reimplemented
from the keiro repository. This redirect also records Keiro's local consumer-adoption status,
because the initiative is not operationally closed for Keiro until its released dependency
bounds and consumer suites have moved together.

The authoritative MasterPlan now lives in the official pgmq-hs repository:

`mori://shinzui/pgmq-hs/masterplans/3-harden-the-pgmq-hs-family-surfaced-by-the-2026-07-review`

Its child plans are:

- NULL semantics: `mori://shinzui/pgmq-hs/plans/13-fix-null-parameter-semantics-across-pop-read-and-notify-statements`
- Notification crash safety: `mori://shinzui/pgmq-hs/plans/14-make-insert-notifications-survive-crashes-and-document-the-channel-contract`
- Queue validation and error classification: `mori://shinzui/pgmq-hs/plans/15-validate-queue-names-and-classify-transient-errors-across-the-pgmq-layers`

The pgmq-hs repository owns implementation progress, migration numbering, shared-file
coordination, release prerequisites, and plan revisions. Keiro remains an in-scope consumer,
but its bounds and compatibility validation are coordinated by
`mori://shinzui/pgmq-hs/plans/12-expose-grouped-reads-on-the-umbrella-api-and-release-0-5-0-0`.

## Progress

- [x] (2026-08-09) Confirmed all three authoritative child plans are Complete and their
  retrospective states that all eleven catalogued findings are fixed and pinned by tests.
- [x] (2026-08-09) Confirmed the fixes shipped in pgmq-hs `0.5.0.0` on 2026-08-06. Hackage
  reports `0.5.0.0` as the newest normal version of
  `mori://shinzui/pgmq-hs/packages/pgmq-core`,
  `mori://shinzui/pgmq-hs/packages/pgmq-config`,
  `mori://shinzui/pgmq-hs/packages/pgmq-effectful`,
  `mori://shinzui/pgmq-hs/packages/pgmq-hasql`, and
  `mori://shinzui/pgmq-hs/packages/pgmq-migration`; tag `v0.5.0.0` of
  `mori://shinzui/pgmq-hs/repos/pgmq-hs` resolves to release commit
  `fc13d7a432dbc0cf0ad4cd3616e5d7d28fdf5abe`.
- [x] (2026-08-09) Confirmed
  `mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter` `0.13.0.0` is published
  on Hackage, tag `v0.13.0.0` resolves to commit
  `7cfdf04ab707e0f6d4fd38bc03256fdfc9b03120`, and its released Cabal metadata requires the
  pgmq `0.5` family.
- [x] (2026-08-09) Upgraded Keiro atomically to the pgmq `0.5` family and
  `mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter` `0.13`. The resolved
  build plan contains pgmq `0.5.0.0` across all five packages and adapter `0.13.0.0`; no
  bounded Keiro component retains the pgmq `0.4` or adapter `0.12` lines.
- [x] (2026-08-09) Validated the library, integration, migration, operator,
  DSL-conformance, and jitsurei consumers with `cabal build all` and the five targeted test
  suites recorded in Outcomes & Retrospective.

## Surprises & Discoveries

- Validation (2026-08-09): Keiro's consumer rollout is not complete. Thirteen direct
  pgmq-family bounds across `keiro-pgmq/keiro-pgmq.cabal`, `jitsurei/jitsurei.cabal`, and
  `keiro-ops/keiro-ops.cabal` still require `>=0.4 && <0.5`. Widening those bounds alone is
  not safe because Keiro also depends on
  `mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter` at
  `>=0.12 && <0.13`, and its newest release, `0.12.0.0`, requires the pgmq `0.4` family.
- Validation (2026-08-09): a forced compatibility build against all five pgmq `0.5.0.0`
  packages gets through the pgmq libraries and then fails while compiling
  `shibuya-pgmq-adapter-0.12.0.0`:

  ```bash
  cabal build keiro-pgmq \
    --allow-newer='all:pgmq-core,all:pgmq-config,all:pgmq-effectful,all:pgmq-hasql,all:pgmq-migration' \
    --constraint='pgmq-core == 0.5.0.0' \
    --constraint='pgmq-config == 0.5.0.0' \
    --constraint='pgmq-effectful == 0.5.0.0' \
    --constraint='pgmq-hasql == 0.5.0.0' \
    --constraint='pgmq-migration == 0.5.0.0'
  ```

  ```text
  src/Shibuya/Adapter/Pgmq/Internal.hs:205:41: error: [GHC-39999]
      Could not deduce HasField "visibilityTime" (Maybe Pgmq.Message) UTCTime
  ```

  This is the expected source break from the hardening release: `setVisibilityTimeoutAt` now
  returns `Maybe Message`, but adapter `0.12.0.0` still treats the result as an unconditional
  `Message`. Keiro's own one-shot visibility-timeout calls discard the result and are
  source-compatible. A released adapter version that handles the missing-row case and admits
  pgmq `0.5` is therefore a hard prerequisite for the Keiro upgrade. Until it exists,
  retaining Keiro's `0.4` bounds preserves a coherent build; changing only the direct bounds
  would make dependency resolution or compilation fail. Re-running `cabal build keiro-pgmq`
  without the forced constraints succeeds against the retained pgmq `0.4` family.
- Validation (2026-08-09): adapter `0.13.0.0` clears that blocker without changing the
  adapter's public records or functions. Its lease extension now treats a raced-away message
  as a successful no-op, its released bounds require pgmq `0.5`, and both Hackage and the
  upstream Git tag identify it as the current release.
- Validation (2026-08-09): the first ordinary solver run still rejected adapter `0.13`
  because the local Cabal index was timestamped before the release. `cabal update` advanced
  the index state to `2026-08-09T13:59:06Z`; the next dry run selected `0.13.0.0`. This was a
  stale local package-index cache, not a compatibility failure.

## Decision Log

- Decision: Supersede keiro MasterPlan 21 with pgmq-hs MasterPlan 3 and preserve this file as
  a redirect for historical links.
  Rationale: The work changes pgmq-hs APIs, migrations, tests, and release artifacts; its
  source-of-truth plans belong beside that code. The relocated plans also incorporate the
  2026-07-23 validation findings.
  Date: 2026-07-23

- Decision: Do not widen Keiro's pgmq-family bounds to `0.5` until a compatible
  `shibuya-pgmq-adapter` release is available.
  Rationale: A forced build proves the latest released adapter is source-incompatible with
  the intentional `Maybe Message` result introduced by pgmq-hs `0.5.0.0`; a bounds-only edit
  would leave Keiro unable to build.
  Date: 2026-08-09

- Decision: Upgrade the pgmq family and `shibuya-pgmq-adapter` as one Keiro dependency-graph
  change now that adapter `0.13.0.0` is released.
  Rationale: Adapter `0.13.0.0` both admits pgmq `0.5` and handles the breaking
  `Maybe Message` lease result. Moving only one side would recreate the solver or compile
  failure captured above, while the paired change preserves one coherent `QueueName` and
  `Message` type family throughout `keiro-pgmq`.
  Date: 2026-08-09

## Outcomes & Retrospective

The authoritative upstream finding-remediation scope is Complete, both required releases are
available, and Keiro's consumer-adoption tail is Complete. The paired upgrade changed thirteen
pgmq-family bounds and three adapter bounds across `keiro-pgmq/keiro-pgmq.cabal`,
`keiro-ops/keiro-ops.cabal`, and `jitsurei/jitsurei.cabal`. Cabal resolved one coherent graph:

```text
pgmq-config             0.5.0.0
pgmq-core               0.5.0.0
pgmq-effectful          0.5.0.0
pgmq-hasql              0.5.0.0
pgmq-migration          0.5.0.0
shibuya-pgmq-adapter    0.13.0.0
```

Validation ran from the repository root:

```bash
cabal build all
cabal test keiro-pgmq-test keiro-ops-test keiro-migrations-test \
  keiro-dsl-conformance-queue-runtime jitsurei-test --test-show-details=direct
```

```text
cabal build all:                              PASS
keiro-pgmq-test:                 58 examples, 0 failures, 2 pending
keiro-ops-test:                  27 examples, 0 failures
keiro-migrations-test:           28 examples, 0 failures
keiro-dsl-conformance-queue-runtime:          PASS
jitsurei-test:                   22 examples, 0 failures
```

The two pending PGMQ examples are unchanged environment/fault-injection limitations: one
needs a deterministic transient-poll fault injector and one needs pg_partman. The upgrade
introduced no new pending or failing behavior. The pgmq-hs implementation remains owned by
the upstream plans; the local tail owned only Keiro's dependency declarations and
compatibility evidence. No new ADR is required because the rollout preserves the ownership
and telemetry boundaries already recorded in
[ADR 1](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md).

## Revision Note

2026-07-23: Replaced the executable plan with this supersession record after relocating and
updating it in the official pgmq-hs repository.

2026-08-09: Validated all upstream findings as fixed and released in pgmq-hs `0.5.0.0`,
replaced absolute cross-repository paths with canonical `mori://` references, and recorded
that Keiro adoption remains blocked by the latest released `shibuya-pgmq-adapter` retaining
the pgmq `0.4` API and bounds.

2026-08-09 (second): Reopened only Keiro's consumer-adoption tail after
`shibuya-pgmq-adapter` `0.13.0.0` cleared the compatibility blocker. Expanded the rollout to
upgrade pgmq `0.5` and adapter `0.13` atomically and made successful consumer-suite validation
the condition for recording the final local status.

2026-08-09 (third): Completed Keiro's consumer-adoption tail. Updated all bounded consumers
to pgmq `>=0.5 && <0.6` and adapter `>=0.13 && <0.14`, verified the exact resolved package
graph, and recorded the successful full build plus targeted PGMQ, migration, operator,
queue-runtime conformance, and jitsurei test results. The MasterPlan remains a supersession
record for upstream implementation, with its local adoption status now Complete.
