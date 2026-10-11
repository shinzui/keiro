---
id: 307
slug: upgrade-to-the-latest-released-shibuya-and-pgmq-hs
title: "Upgrade to the latest released shibuya and pgmq-hs"
kind: exec-plan
created_at: 2026-10-11T22:52:52Z
intention: "intention_01m4pjm2w7eknrndx0d6zcmf10"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-11T22:52:52Z
---

# Upgrade to the latest released shibuya and pgmq-hs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Make Keiro require and validate the latest published Shibuya and pgmq-hs releases: `shibuya-core 0.10.0.1` and all five pgmq-hs libraries at `0.6.1.1`, verified on 2026-10-11. Applications should continue to enqueue, consume, retry, and dead-letter jobs, preserve grouped ordering, and stop workers cleanly using ordinary Hackage dependencies. The benefit is a reproducible supported minimum that admits Shibuya's random 1.3 compatibility and pgmq-hs's Effectful 2.7 and pg-migrate 1.2 compatibility, with dependency metadata that describes the same contract.

The working tree already resolves these releases. This work makes that selection a declared requirement and proves it through the existing PostgreSQL integration and generated-code suites. Run `cabal test keiro-pgmq-test --test-show-details=direct` to observe queue lifecycle behavior and inspect `dist-newstyle/cache/plan.json` to prove which published versions were actually used. This plan creates no new queue feature and does not publish a Keiro release.


## Progress

Implementation has not started. The following entries describe remaining work, not completed planning research.

- [ ] Refresh release evidence and raise the Shibuya and pgmq-hs minimums in every bounded Cabal consumer.
- [ ] Align the affected `mori.dhall` dependency constraints and demonstrate Hackage-only resolution.
- [ ] Build all components and validate queue, worker, telemetry, operator, and generated-code behavior.
- [ ] Document the supported release cohort, complete `just verify`, and record the final resolved versions.
- [ ] Perform ADR distillation and record Outcomes & Retrospective before marking implementation complete.


## Surprises & Discoveries

(None yet.)


## Decision Log

Decision (2026-10-11): Interpret “latest” as the latest normally preferred release available from Hackage and corroborated by upstream tags. Target `shibuya-core 0.10.0.1`, `pgmq-config`, `pgmq-core`, `pgmq-effectful`, `pgmq-hasql`, and `pgmq-migration` at `0.6.1.1`, with the already-required `shibuya-pgmq-adapter 0.16.1.0`. Rationale: local checkouts contain unreleased API changes; those are not the user's requested released dependency upgrade. Recheck releases immediately before implementation and revise this entire plan if a newer release changes the target or API assumptions.

Decision (2026-10-11): Raise `shibuya-core` to `^>=0.10.0.1` and each explicitly bounded pgmq-hs dependency to `>=0.6.1.1 && <0.7`. Keep the compatible adapter at `^>=0.16.1.0`. Rationale: the current build already selects the latest versions, while the declared lower bounds still admit earlier packages. Preserve the current compatible upper bounds and avoid permanent exact-version constraints in a reusable library.

Decision (2026-10-11): Reuse the existing behavioral integration suites and make production Haskell edits only for demonstrated incompatibilities. Rationale: tagged production sources did not change across these patch updates, and constructor changes advertised under the local checkouts' Unreleased sections would wrongly expand this task.

Decision (2026-10-11): Keep the long-polling repair in `docs/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6.md` separate. Rationale: `LongPoll` still maps to server-side `LongPolling` in the working tree; a dependency upgrade neither fixes that behavior nor justifies marking those bug reports fixed. Similarly, no upstream unreleased inspection API or transient-error classification is adopted here.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Keiro is a multi-package Haskell project. `cabal.project` lists its libraries, examples, and generated-code conformance packages. Cabal is the dependency solver and build runner; a lower bound declares the oldest supported package version, while an upper bound excludes untested incompatible releases. `^>=0.10.0.1` means `>=0.10.0.1 && <0.11`. A release cohort here means the related versions tested together, not a new Keiro package version.

`keiro/keiro.cabal` bounds `shibuya-core ^>=0.10.0.0` in its library, tests, retention suite, and benchmark. `keiro-pgmq/keiro-pgmq.cabal` uses that Shibuya bound and `shibuya-pgmq-adapter ^>=0.16.1.0`; its library bounds `pgmq-config`, `pgmq-core`, `pgmq-effectful`, and `pgmq-hasql` at `>=0.6 && <0.7`, and its test suite bounds the first three the same way and `pgmq-migration >=0.6.1.1 && <0.7`. `keiro-dsl/keiro-dsl.cabal` has bounded Shibuya consumers and several unbounded test-only Shibuya/PGMQ imports. `jitsurei/jitsurei.cabal` bounds Shibuya and PGMQ in example and test components. `keiro-ops/keiro-ops.cabal` already requires `pgmq-migration >=0.6.1.1 && <0.7` in tests. Preserve those already-correct bounds. Do not invent direct dependencies in packages which consume the libraries only through Keiro.

`mori.dhall` separately describes dependency relationships for the Mori registry. Its three Shibuya constraints still say `^>=0.9.0.0`, its PGMQ adapter constraint says `^>=0.16.0.0`, and its five pgmq-hs constraints say `>=0.6 && <0.7`. They lag the Cabal files even though the registry's package references are correctly wired. Edit only these affected dependency records and preserve unrelated current changes.

`keiro-pgmq/src/Keiro/PGMQ/Runtime.hs` owns queue naming, connection-pool lifetime, and `runJobEff`, which interprets queue operations against PostgreSQL, with tracing enabled or disabled. `keiro-pgmq/src/Keiro/PGMQ/Job.hs` builds adapter configuration in `adapterConfigFor`, starts supervised continuous workers in `runJobWorkers`, and implements the separate bounded drain in `runJobOnceWithContext`. An acknowledgement settles a delivery by deleting it, delaying its next visibility, or moving it to a dead-letter queue (DLQ), where failed work remains available for inspection. A visibility timeout temporarily hides leased work; FIFO ordering means earlier messages in one group block its successors while other groups can progress. `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` and `keiro-pgmq/src/Keiro/PGMQ/Metrics.hs` expose supported operations rather than duplicating the underlying library's SQL. `keiro-ops/src/Keiro/Ops/Pgmq.hs` wraps that public API for operators.

`keiro-pgmq/test/Main.hs` starts a suite-level temporary PostgreSQL server through `Keiro.Test.Postgres` and installs `Pgmq.Migration.pgmqMigrations` alongside the framework's migration components. Each example gets a fresh cloned database. Tests exercise queue creation, `Done`, `Retry`, `Dead`, malformed payloads, retry exhaustion, lease extension, grouped-head ordering, DLQ archive/purge, and trace-parent propagation. Two examples are currently pending: transient polling fault injection and live partition provisioning requiring pg_partman, PostgreSQL's partition-management extension. These are existing coverage limitations, not successful upgrade evidence. `keiro/test/Main.hs`, `keiro-ops/test/Main.hs`, and the suites declared in `keiro-dsl/keiro-dsl.cabal` exercise the broader consumers. Use `keiro-dsl:tests` to run every generated-code suite rather than a bare package target that can select only one.

`flake.nix`, `nix/haskell.nix`, and `flake.module.nix` provide the GHC 9.12.4 development shell, PostgreSQL 18 tools, and librdkafka native build dependencies. They do not pin Shibuya or pgmq-hs source releases. `cabal.project` has a source-repository override for codd and `allow-newer: haxl:time`, neither related to this upgrade. There is no reason to refresh `flake.lock` or add a dependency source override to this task. Never traverse `/nix/store` to find library code.

Dependency sources and documentation were discovered through Mori. The canonical projects are `mori://shinzui/shibuya`, `mori://shinzui/shibuya-pgmq-adapter`, and `mori://shinzui/pgmq-hs`; exact package references include `mori://shinzui/shibuya/packages/shibuya-core` and `mori://shinzui/pgmq-hs/packages/pgmq-migration`. Shibuya's registered changelog is `mori://shinzui/shibuya/docs/changelog`; pgmq-hs queue guidance is `mori://shinzui/pgmq-hs/docs/queue-configuration`. Resolve sources through Mori and inspect tagged files, because both local projects have Unreleased changes.

On 2026-10-11, Hackage's package JSON and preferred-version endpoints agreed with upstream tags. Shibuya `v0.10.0.1` resolves to commit `de42f07a874bd7d59aff7e41e7ac07b7333f1397`; pgmq-hs `v0.6.1.1` resolves to `696b6bd28f29e1ea53d07bf66d2d6d59f1182fa3`; the compatible PGMQ adapter `v0.16.1.0` resolves to `6ce44abb28c983ede774ac8c6a9ada9c96b0a65f`. The registry evidence is available at [Shibuya preferred versions](https://hackage.haskell.org/package/shibuya-core/preferred.json) and [PGMQ preferred versions](https://hackage.haskell.org/package/pgmq-core/preferred.json), with the analogous endpoint for each family member. The five pgmq-hs libraries all publish the same version.

Tagged Shibuya `0.10.0.0` to `0.10.0.1` expands `random` compatibility to `>=1.2 && <1.4`; its released `AppConfig` still has just `strategy` and `inboxSize`. Tagged pgmq-hs `0.6.0.0` to `0.6.1.1` changes package bounds and test infrastructure, without production Haskell or migration SQL changes: the effect layer supports Effectful 2.6 and 2.7, and `pgmq-migration` admits pg-migrate 1.1 and 1.2. Keiro already excludes Effectful 2.7.0.0 through 2.7.1.0. Preserve that constraint. Unreleased Shibuya metrics-detail fields and pgmq-hs inspection/error-classification additions are excluded. Shibuya metrics is not a direct Keiro dependency and needs no new integration.

Creation-time `cabal build all --dry-run` returned `Up to date`; the existing `dist-newstyle/cache/plan.json` lists the target Shibuya and five pgmq-hs versions with `pkg-src.type = repo-tar`, meaning Hackage archive sources. It also selects `shibuya-pgmq-adapter 0.16.1.0` and `shibuya-kiroku-adapter 0.6.0.1`. That observation is not a substitute for implementation-time index refresh, build, and behavioral tests. Preserve the Kiroku adapter bound and current Kiroku migration work.

Relevant local ADRs were consulted. [ADR-1](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md) requires one process span per delivery and a shared acknowledgement vocabulary across continuous workers and bounded drains, while retaining their different execution semantics. [ADR-25](../adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md) requires retryable work to remain recoverable, truthful completed-work counts, and cancellation to propagate. [ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md) requires operator commands to call the owning library's supported API rather than query or mutate its private tables. [ADR-45](../adr/0045-pgmq-provisioning-preserves-upstream-sql-and-bounds-local-retention-validation.md) preserves upstream provisioning SQL and bounded retention validation; partition retention can discard unprocessed work and conventional FIFO-index presence is not proof of acceleration. This upgrade preserves those decisions. ADRs are a profiled OKF bundle in `mori.dhall`, governed by `docs/adr/profile.dhall` and strict validation.

The creation-time tree contains unrelated modified Cabal files, changelogs, `mori.dhall`, and `keiro-migrations/test/Main.hs`. Preserve these edits; treat the current tree as the starting point, and stage only this plan's own changes when later committing. This is a standalone plan with its own intention, not a child of an existing MasterPlan.


## Plan of Work

### Milestone 1: Declare the verified released dependency cohort


Refresh Hackage and tag evidence using the commands below. Change every existing bounded `shibuya-core ^>=0.10.0.0` occurrence in `keiro/keiro.cabal`, `keiro-pgmq/keiro-pgmq.cabal`, `keiro-dsl/keiro-dsl.cabal`, and `jitsurei/jitsurei.cabal` to `^>=0.10.0.1`. Raise every existing `>=0.6 && <0.7` pgmq-hs bound in `keiro-pgmq/keiro-pgmq.cabal` and `jitsurei/jitsurei.cabal` to `>=0.6.1.1 && <0.7`. Keep already-correct `pgmq-migration` and PGMQ adapter bounds. Keep the DSL's unbounded test-only imports unless the solver demonstrates an independent need; the bounded local dependency already enforces the cohort. Do not change local Keiro versions or the Kiroku release family.

Update the three affected Shibuya records, the PGMQ adapter record, and five pgmq-hs records in `mori.dhall` to the corresponding Cabal constraints. A registry descriptor is metadata, not an extra solver. Run a fresh all-component dry run with tests and benchmarks enabled, inspect the plan JSON, and type-check the descriptor with `dhall type --file mori.dhall`. Acceptance is successful resolution to the verified releases from Hackage with no Shibuya/PGMQ source override, no stale affected bound, and no changed unrelated descriptor records.

### Milestone 2: Prove existing integrations on that cohort


Build all components with tests and benchmarks enabled, then run the full PGMQ, main Keiro, operator, and generated DSL test suites. The observable result is jobs disappearing on `Done`, remaining leased or delayed on `Retry`, reaching exactly the expected DLQ path on `Dead` or retry exhaustion, and group successors waiting behind delayed or failed heads while independent groups progress. Existing worker tests also demonstrate lease extension and bounded shutdown; existing trace tests demonstrate the parent trace and truthful acknowledgement status. Run `keiro-migrations-test` as the companion framework migration gate; the PGMQ suite itself exercises composition with the released `pgmq-migration` component.

No production adaptation is expected. If compilation shows a real incompatibility, inspect the released source through Mori first, then make the smallest fix in `Keiro.PGMQ.Job`, `Keiro.PGMQ.Runtime`, or the affected consumer module. Preserve the public interface and ADR contracts. Add a behavioral test only if a production change exposes a previously uncovered scenario, using the existing fresh-database fixture. A patch-bound upgrade does not require mirrored metadata tests. Acceptance is zero failures in the affected suites, with only the two known PGMQ pending examples recorded as limitations. Do not claim outage recovery from the pending transient-fault example, or live partition support from the pending pg_partman example.

### Milestone 3: Record support and complete repository validation


Add concise Unreleased changelog entries in `CHANGELOG.md`, `keiro/CHANGELOG.md`, `keiro-pgmq/CHANGELOG.md`, and `keiro-dsl/CHANGELOG.md` describing the minimum published dependency versions and compatibility rationale. Change other package changelogs only if their requirements actually changed. Preserve unrelated release work. Existing queue APIs and behavior remain the same, so no user-guide rewrite is required unless Milestone 2 changes an observable contract.

Run `just verify` in the development shell and record its actual exit status and final selected versions in this plan. This includes examples against the local development database, retention tests, all declared DSL suites, policy checks, and strict documentation validation. Record pre-existing failures separately and resolve upgrade-caused failures before completion; a blocked command or truncated log is not a pass. Review decisions and discoveries for durable architectural changes. A bounds-only upgrade should require no new ADR; state that conclusion in Outcomes & Retrospective. If an API adaptation changes a durable contract, update its existing ADR or allocate a new stable handle using OKF, update the bundle log, and validate strictly. Acceptance is a fully passing repository gate, recorded released-package evidence, updated documentation, and a final retrospective explaining what the upgrade guarantees and which unrelated queue issues remain open.


## Concrete Steps

Run all commands from the repository root. Enter the shell once if GHC, Cabal, PostgreSQL, or native libraries are unavailable. The shell initializes the local development database directory but does not start PostgreSQL until the relevant recipes do so. Python 3, Bun, Mori, Dhall, and OKF must also be available on the host or shell path.

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
git status --short
nix develop
ghc --numeric-version
cabal --version
```

Expect GHC `9.12.4`. Record the initial dirty files before editing. Discover dependency roots and registered documentation before reading any dependency API:

```bash
mori registry list
mori registry search shibuya
mori registry search pgmq-hs
mori registry show shinzui/shibuya --full
mori registry show shinzui/pgmq-hs --full
mori registry show shinzui/shibuya-pgmq-adapter --full
mori registry docs shinzui/shibuya
mori registry docs shinzui/pgmq-hs
mori path mori://shinzui/shibuya
mori path mori://shinzui/pgmq-hs
```

Recheck the package registry and tags. The script reads authoritative preferred versions and fails if the creation-time release targets are no longer current; revise the plan before choosing newer targets. The tag commands should display the commits recorded above on the peeled `^{}` lines.

```bash
python3 - <<'PY'
import json
import urllib.request

targets = {'shibuya-core': '0.10.0.1', 'shibuya-pgmq-adapter': '0.16.1.0'}
targets.update({name: '0.6.1.1' for name in (
    'pgmq-config', 'pgmq-core', 'pgmq-effectful', 'pgmq-hasql', 'pgmq-migration')})
for name, expected in targets.items():
    url = f'https://hackage.haskell.org/package/{name}/preferred.json'
    with urllib.request.urlopen(url) as response:
        versions = json.load(response)['normal-version']
    latest = max(versions, key=lambda version: tuple(map(int, version.split('.'))))
    print(name, latest)
    assert latest == expected, f'{name}: refresh this plan for {latest}'
PY
git ls-remote --tags https://github.com/shinzui/shibuya.git 'refs/tags/v0.10.0.1*'
git ls-remote --tags https://github.com/shinzui/pgmq-hs.git 'refs/tags/v0.6.1.1*'
git ls-remote --tags https://github.com/shinzui/shibuya-pgmq-adapter.git 'refs/tags/v0.16.1.0*'
```

Use the Mori-resolved project roots to inspect tagged API changes without touching the source checkouts. The current Mori command prints the URI followed by its path, hence `tail -n 1`. If the CLI changes output shape, use the path it displays explicitly. Fetch a missing tag from that repository's configured upstream before comparing; do not inspect installed package files in `/nix/store`.

```bash
shibuya_source=$(mori path mori://shinzui/shibuya | tail -n 1)
pgmq_source=$(mori path mori://shinzui/pgmq-hs | tail -n 1)
git -C "$shibuya_source" diff v0.10.0.0 v0.10.0.1 -- shibuya-core
git -C "$shibuya_source" show v0.10.0.1:shibuya-core/src/Shibuya/App.hs
git -C "$pgmq_source" diff v0.6.0.0 v0.6.1.1 -- pgmq-core pgmq-hasql pgmq-effectful pgmq-config pgmq-migration
git -C "$pgmq_source" show v0.6.1.1:pgmq-migration/src/Pgmq/Migration.hs
```

Apply Milestone 1's edits. These searches are an inventory, not instructions to replace every occurrence indiscriminately. Existing test-only unbounded imports can remain. After editing, the explicitly bounded consumers must use the chosen minimums and the Mori records must match.

```bash
rg -n 'shibuya-core|shibuya-pgmq-adapter|pgmq-(config|core|effectful|hasql|migration)' --glob '*.cabal' --glob '!dist-newstyle/**' .
rg -n 'shibuya|pgmq|versionConstraint' mori.dhall
dhall type --file mori.dhall
cabal update
cabal build all --dry-run --enable-tests --enable-benchmarks
```

Print and assert the actual resolved versions and source type. Run this again after final validation. Exact selection is evidence for this implementation run; package declarations retain compatible ranges for future patch releases.

```bash
python3 - <<'PY'
import json

targets = {'shibuya-core': '0.10.0.1', 'shibuya-pgmq-adapter': '0.16.1.0'}
targets.update({name: '0.6.1.1' for name in (
    'pgmq-config', 'pgmq-core', 'pgmq-effectful', 'pgmq-hasql', 'pgmq-migration')})
with open('dist-newstyle/cache/plan.json') as stream:
    entries = json.load(stream)['install-plan']
for name, version in sorted(targets.items()):
    selected = [entry for entry in entries if entry['pkg-name'] == name]
    assert selected, f'{name}: missing from solver plan'
    for entry in selected:
        source = entry.get('pkg-src', {}).get('type')
        print(name, entry['pkg-version'], source)
        assert entry['pkg-version'] == version, entry
        assert source == 'repo-tar', f'{name}: not a Hackage archive'
PY
```

The expected unique version lines are:

```text
pgmq-config 0.6.1.1 repo-tar
pgmq-core 0.6.1.1 repo-tar
pgmq-effectful 0.6.1.1 repo-tar
pgmq-hasql 0.6.1.1 repo-tar
pgmq-migration 0.6.1.1 repo-tar
shibuya-core 0.10.0.1 repo-tar
shibuya-pgmq-adapter 0.16.1.0 repo-tar
```

Run Milestone 2's build and focused behavioral gates. The fresh-database test fixture starts its own PostgreSQL server; no production connection string or running shared server is required for those tests.

```bash
cabal build all --enable-tests --enable-benchmarks
cabal test keiro-pgmq-test --test-show-details=direct
cabal test keiro-test keiro-ops-test keiro-migrations-test --test-show-details=direct
cabal test keiro-dsl:tests --test-show-details=direct
```

Hspec summaries must report zero failures. Record the PGMQ example and pending counts actually observed, with names and reasons for the known pending tests. After changelog edits, run the repository's complete gate once; the `just verify` recipes create/use the local jitsurei development database, so use the checkout's development environment.

```bash
just verify
git diff --check
git diff --stat
```

If an ADR changes, follow the existing profiled bundle. New records need a stable handle; existing handles must be preserved. Use the allocated handle when updating the log, and require the final strict validation to pass.

```bash
mori show --full
dhall type --file docs/adr/profile.dhall
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf log add docs/adr ADR-N
just adr-validate
```

`ADR-N` in the log command is a placeholder for the actual existing or newly allocated handle. Do not allocate or create an ADR merely to record a dependency patch version. Record one implementation provenance revision when first updating this plan during implementation, using the skill's `record-provenance.ts` runtime-model discovery procedure. For commits, keep the current branch, stage only owned changes, use Conventional Commits, and include both trailers:

```text
chore(deps): require current shibuya and pgmq-hs releases

ExecPlan: docs/plans/307-upgrade-to-the-latest-released-shibuya-and-pgmq-hs.md
Intention: intention_01m4pjm2w7eknrndx0d6zcmf10
```


## Validation and Acceptance

The dependency contract is observable in both declaration and resolution: no bounded Shibuya consumer accepts a version below `0.10.0.1`, no bounded pgmq-hs consumer accepts one below `0.6.1.1`, the affected Mori records agree, and the refreshed solver chooses the target published archives with the compatible `0.16.1.0` adapter. `cabal build all --enable-tests --enable-benchmarks` must compile every local consumer, including generated-code and example components.

`cabal test keiro-pgmq-test --test-show-details=direct` must prove existing public behavior. In `keiro-pgmq/test/Main.hs`, “runJobWorkers processes an enqueued message” must observe the handler and empty queue; “worker-path lease extension prevents redelivery” must run the slow handler once; “FifoHeads blocks a group successor when its head returns Retry” must leave that successor blocked; “FifoHeads worker retries a failed head before its successor while other groups progress” must preserve group order and independent progress. The one-shot process-span examples must preserve the remote trace parent, `ack_retry`/`ack_dead_letter` vocabulary, and absence of an acknowledgement claim when a handler throws. DLQ inspection, archive-by-id idempotence, hidden-row purge refusal, and archived-row survival must remain passing.

The main Keiro and operator suites must preserve router/process-manager settlement and supported DLQ command behavior. Every `keiro-dsl:tests` suite must pass, so scaffolded handlers and generated acknowledgement policies continue to compile and run against the upgraded runtime. `just verify` must finish successfully, including retention, migration, example, conformance, and policy gates. Record genuine failures and the final exit status rather than declaring completion from a solver plan alone. Existing pending examples and the separate long-polling defects remain explicitly outside the completion claim.


## Idempotence and Recovery

Release lookup, dependency discovery, type checks, solver inspection, builds, and cloned-database tests can be repeated. Test databases are disposable and managed by `Keiro.Test.Postgres`; let the fixture clean them up. `just verify` uses the named local development database for examples. If its state is inconsistent, diagnose it through the repository's supported migration/example recipes rather than deleting databases or modifying upstream migration SQL.

No new migration is expected because the target pgmq-hs patch releases do not change migration bytes. Do not edit historical files or migration locks to force compatibility. If refresh unexpectedly selects incompatible transitive packages, inspect the owning dependency through Mori and its authoritative release metadata, then record the actual constraint conflict before making a narrowly justified adjustment. Do not add `allow-newer` or unreleased source overrides as a silent workaround.

Preserve all pre-existing dirty edits. To back out an unsuccessful attempt, reverse only this plan's hunks or its dedicated committed changes; never broadly restore the Cabal files, changelogs, or `mori.dhall`. If an unrelated test failure prevents the full gate, record its reproduction and keep the implementation progress incomplete. Keep terminal capture under a specific local log path if needed, preserve command exit status, and avoid repeating broad gates after they have passed unless new edits warrant it.


## Interfaces and Dependencies

Use `mori://shinzui/shibuya/packages/shibuya-core` at `^>=0.10.0.1` for supervised processors, acknowledgement types, and telemetry; use `mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter` at `^>=0.16.1.0` for queue delivery and transactional settlement. Preserve the existing `mori://shinzui/kiroku/packages/shibuya-kiroku-adapter` dependency and its current bound; it is a compatibility consumer, not a target release change.

Require `mori://shinzui/pgmq-hs/packages/pgmq-core`, `mori://shinzui/pgmq-hs/packages/pgmq-hasql`, `mori://shinzui/pgmq-hs/packages/pgmq-effectful`, `mori://shinzui/pgmq-hs/packages/pgmq-config`, and `mori://shinzui/pgmq-hs/packages/pgmq-migration` at `>=0.6.1.1 && <0.7` wherever they already have explicit bounds. They provide queue types, database operations, effect interpreters, additive provisioning, and native migration components respectively. The migration package's published 1.1/1.2 pg-migrate compatibility must coexist with the current Keiro migration requirements without widening unrelated ranges.

No new public type or function is required. Preserve `Keiro.PGMQ.Runtime.withJobRuntime :: Text -> Maybe Tracer -> (JobRuntime -> IO a) -> IO a`, `Keiro.PGMQ.Runtime.runJobEff`, `Keiro.PGMQ.Job.runJobWorkers`, `Keiro.PGMQ.Job.runJobOnceWithContext`, queue naming, tuning validation, and the existing `JobOutcome` mapping. Released `Shibuya.App.AppConfig` has `strategy` and `inboxSize`; use that tagged contract rather than supplying unreleased fields. `Pgmq.Migration.pgmqMigrations` remains the native component source, and `Pgmq.Config.Effectful.ensureQueuesEff` remains the provisioning path. Existing trace and FIFO behavior, upstream schema ownership, and cancellation semantics remain acceptance requirements throughout all milestones.
