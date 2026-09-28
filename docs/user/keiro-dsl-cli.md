---
type: Reference
title: Keiro DSL Command Reference
description: Run the keiro-dsl new, parse, pretty, check, inspect, behavior-obligations, scaffold, and diff commands.
docId: DOC-33
tags: [keiro, dsl, cli, reference]
generated:
  by: anthropic-claude-code/claude-opus-5
  at: 2026-09-28T00:00:00Z
---

# Keiro DSL Command Reference

This page describes every `keiro-dsl` command and its options. It is part of the [Keiro DSL Reference](keiro-dsl-reference.md), which
introduces the language, its versions, and source file structure.

## Command reference

The examples below use Cabal from the Keiro repository. If
`keiro-dsl/bin` is on `PATH`, replace `cabal run -v0 keiro-dsl --` with
`keiro-dsl`.

Every command that accepts `FILE` accepts a `.keiro` source, a
`.keiro-workspace` manifest, or `/dev/stdin`.

### `new`

```bash
cabal run -v0 keiro-dsl -- new KIND
```

Valid kinds are `aggregate`, `process`, `router`, `contract`, `intake`, `emit`,
`publisher`, `workqueue`, `dispatch`, `workflow`, and `operation`. Every starter
is a complete, checked stable Language 5 service because `new` uses
`currentStableLanguageVersion`, even while the Language 6 candidate is
registered. Coupled kinds include the nodes they
need; for example, the publisher starter includes a contract and emit. There is
no standalone read-model starter; the workqueue starter includes read models.

### `parse` and `pretty`

```bash
cabal run -v0 keiro-dsl -- parse service.keiro
cabal run -v0 keiro-dsl -- pretty service.keiro
```

Both parse and print canonical source. They catch grammar errors but do not run
semantic validation. Canonical output discards comments and formatting.

### `check`

```bash
cabal run -v0 keiro-dsl -- check service.keiro
cabal run -v0 keiro-dsl -- check service.keiro --emit
cabal run -v0 keiro-dsl -- check service.keiro --explain-bindings
cabal run -v0 keiro-dsl -- check service.keiro --min-language 5
cabal run -v0 keiro-dsl -- check service.keiro --deny-warnings
cabal run -v0 keiro-dsl -- check service.keiro \
  --deny DeprecatedEventReplayHazard,WireSchemaVersionMismatch
cabal run -v0 keiro-dsl -- check service.keiro \
  --report-out build/keiro-check-report.json
cabal run -v0 keiro-dsl -- check service.keiro \
  --coverage-report build/keiro-coverage.json \
  --fail-on-opaque
```

`--emit` prints canonical source after successful validation.
`--explain-bindings` lists consumer-owned binding obligations.
`--min-language N` requires a registered released language version at least
`N`; `--min-language 5` is the standard stable-contract gate for newly adopted services.
`--deny-warnings` makes every warning fail this invocation without changing its
severity. `--deny CODE[,CODE...]` applies the same exit policy selectively; it
is repeatable, and the spelling is copied exactly from `warning[Code]`. A code
`check` cannot emit is refused rather than silently accepted: cross-revision
codes belong to `diff`, and structural-coverage codes require
`--coverage-report` in the same invocation. This makes a denial in a CI file
either effective or an immediate error, never a decoration.
`--report-out` writes `keiro-dsl/check-report/1` after source or workspace
validation, on success or failure, creating missing parent directories. It
records language provenance, enforcement flags, diagnostics and related
locations, summary counts, the validation outcome, and an appended
`processReactions` array (process, verification, version, fingerprint, hole
obligations). Object and array-element
keys are append-only; readers must ignore unknown keys. A parse failure and an
unreadable or unparseable workspace manifest occur before any coded diagnostic
exists and therefore write no report; a *composed* workspace refusal does write
one, with `"language": null` because no service graph was formed.
`--coverage-report` inventories structural, opaque, explicit-`Json`,
consumer-JSON register, and nominal boundaries. Each `nominalBoundaries` row
names its complete path and root, ID/scalar kind, ID prefix/domain version or
consumer canonical type/ownership. Nominal-only queue and query roots count as
structural rather than opaque. `--fail-on-opaque` turns named private
persisted opaque boundaries into a CI gate. Coverage findings are part of this
invocation's diagnostic surface: they are subject to the same warning policy and
appear in the check report as line-0 entries, so the report's `ok` covers them.
Both reports spell severity `"error"` or `"warning"`.

#### CI recipe

```bash
cabal run -v0 keiro-dsl -- check service.keiro \
  --min-language 5 \
  --deny-warnings \
  --report-out build/keiro-check-report.json
```

A red result means the source did not parse or compose, selected a language
below 5, emitted an error, or emitted a warning denied by this invocation. The
JSON report distinguishes those outcomes whenever a coded diagnostic could be
produced. The report's parent directory is created if it does not exist.

### `inspect`

```bash
cabal run -v0 keiro-dsl -- inspect service.keiro --format=json
```

The report records declared Language 4 provenance, its effective semantic
contract, and `languageSupport: "stable"`. Workspace output lists every member
in canonical path order.

### `behavior-obligations`

```bash
cabal run -v0 keiro-dsl -- behavior-obligations service.keiro --format=text
cabal run -v0 keiro-dsl -- behavior-obligations service.keiro --format=json
```

Use text while authoring and the stable JSON schema for CI or other tooling.
Both forms resolve every behavior key through the checked source index; JSON
keeps schema `keiro-dsl/behavior-obligations/1` and appends `file`, `column`,
and `quality: "exact"` to each location.

### `scaffold`

```bash
cabal run -v0 keiro-dsl -- scaffold service.keiro --out src \
  --runtime-package acme-service-runtime \
  --module-root Acme.Services \
  --collocate \
  --goldens test/golden-payloads
```

Options:

- `--out DIR` is required.
- `--module-root PREFIX` overrides the source module clause.
- `--runtime-package PACKAGE` enables the runnable conformance package and
  overrides a workspace manifest's `runtime-package` value.
- `--collocate` selects collocated generated placement.
- `--force-generated-overwrite` allows replacement of a generated target that
  lacks the expected banner. Use only after proving the target is disposable.
- `--goldens DIR` selects aggregate golden-payload input.
- `--codec-comparison MAPPED-NAME --comparison-out FILE` emits a
  non-production historical codec comparison module for one structural mapped
  type.

The scaffold report includes a `no-modules:` line for every declared emit,
pgmq dispatch, or operation. Those nodes remain validated and diff-classified;
the line makes explicit that they contributed no generated modules.

For mapped declarations, read `semantic impact` separately from
`generated-artifact impact`. Semantic impact comes from the checked dependency
graph and names previous/current aggregate, workqueue, read-model query-position,
and derived projection consumers. It prints complete logical roots and separate
consumer-build, event-history, snapshot-hydration, queued-job-history, query-API,
projection-handler, and replayable-rebuild consequences. The one service-wide
structural-conformance role remains independent. Artifact impact reports which
generated bytes actually changed, distinguishing aggregate modules,
`StructuralConformance`, and `BehaviorSourceMap`. A file disposition never adds
a semantic consumer. In particular, moving otherwise unchanged source text may
change only `BehaviorSourceMap` and report no mapped semantic impact.

Current standalone and workspace ledgers persist the source-independent
semantic baseline. If the previous ledger predates that row, the report says
`baseline: unavailable (legacy ledger)` and names only current consumers; it
does not guess that the old consumer set was empty. The successful run writes
the baseline, so a later run can compare both sides.

The ledgers also persist one router-selection snapshot per router. Declarative
selections record `declarative-verified` identity, version, and fingerprint;
custom resolver forms record `custom-unverified` with no fabricated metadata.
An older ledger with no router-selection row remains readable and gains the row
on the next successful scaffold.

For historical comparison, compile the emitted module in a consumer-owned test
and supply the old codec explicitly. The tool does not discover or fall back to
an old application instance at runtime.

### `diff`

```bash
cabal run -v0 keiro-dsl -- diff service.keiro --since HEAD^ --explain \
  --deny AggGuardRelationUnknown,AggGuardRemedyUnavailable \
  --report-out build/keiro-diff.json \
  --replay-impact-out build/replay-impact.json
```

`diff` reconstructs the old source or workspace from Git and classifies every
finding across six compatibility surfaces:

```text
private-history-read
old-binary-read-new-events
snapshot-hydration
public-consumer
persisted-identity
consumer-build
```

Mapped findings also receive a separate `semantic impact` block. It summarizes
the checked old/current typed consumers, roots, consequences, and service
conformance role. Queue and query positions stay distinct, and only replayable
catalog projection consumers name a rebuild consequence. It does not replace
the detailed compatibility findings, rollout constraints, or replay report.
`--report-out` appends the same sorted projection under
`semanticImpact` while keeping schema `keiro-dsl/diff-report/1`. Source-only or
ownership-only movement has no mapped semantic-impact entries.

`--deny CODE[,CODE...]` is repeatable and promotes the named advisories to a
failing exit for this invocation only. It accepts only codes that `diff` can
emit; a `check`-only code is refused rather than silently ignored.

Three evolution codes need explicit rollout attention:

- `AggGuardRelationUnknown` is an append-only advisory emitted when live
  emitting sibling remainders are ambiguous. No replay-only twin is guessed;
  review the history and do not deploy until the relation is understood.
- `AggGuardRemedyUnavailable` means a computed replay-only twin failed its
  render, parse, replay-identity, or validation proof. The report deliberately
  omits a paste-ready transition.
- `IntakeIdempotenceModeChanged` is a persisted-identity compatibility break.
  Inbox-table rows and downstream-owned receipts are not interchangeable, so a
  move between `table` and `delegated` requires an explicit cutover.

Changes to a nominal prefix, domain contract, representation, binding,
fixtures, or canonical type are reported at every direct or structural use.
Nested event paths use the private-event context, register paths use the
snapshot context, workqueue fields retain queue rollout consequences, and
command and query paths use consumer-build context; query consequences remain
build-only. Fixture changes are evidence-only, and a nominal `initial` symbol
is not attributed to a nominal nested inside a structural register.

Declarative router changes also receive a separate `coordination impact` block.
It reports old/current verification, identity, version, fingerprint, and mapped
use sites. The JSON form appends the same sorted evidence as optional top-level
`coordinationImpact`; legacy report constructors omit the key. Identity changes,
version decreases, and semantic fingerprint changes without a version increase
are breaking. A changed fingerprint with a version increase, a metadata-only
version increase, a declarative/custom boundary crossing, or an affected mapped
selection dependency is advisory. Coordination-breaking findings participate
in the report headline and command exit status; aggregate `ReplayImpact` remains
a separate unchanged contract.

The headline is `ADDITIVE`, `WARNING`, or `BREAKING`. The default gate includes
all surfaces except `old-binary-read-new-events`; repeat `--gate SURFACE` to add
that or any future optional gate. `--explain` prints paths, failing directions,
rollout constraints, and remedies. `--report-out` writes the stable
`keiro-dsl/diff-report/1` JSON report.

Other options:

- `--emit-goldens DIR` writes old-shape payloads for event version bumps
  without overwriting existing files.
- `--replay-impact-out FILE` writes the replay-neutral or replay-affected audit
  input.
- `--coverage-report FILE` writes the mapped-boundary delta.
- `--fail-on-opaque-increase` fails when the change adds a named opaque
  boundary; it requires `--coverage-report`.

Run `diff` from the Git repository containing the source because `--since`
uses `git show`.
