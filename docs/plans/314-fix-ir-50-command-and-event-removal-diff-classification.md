---
id: 314
slug: fix-ir-50-command-and-event-removal-diff-classification
title: "Fix IR-50 command and event removal diff classification"
kind: exec-plan
created_at: 2026-10-14T13:48:08Z
intention: "intention_01m4xaptn7exgbtwqm4ej06fye"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-14T13:48:08Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T13:54:09Z
      mode: "other"
      note: "Completed initial IR-50 plan with own-revision fold evidence, CLI and workspace regressions, and report acceptance criteria."
---

# Fix IR-50 command and event removal diff classification


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Promote durable decisions into the relevant ADRs before completion.

## Purpose / Big Picture


A developer removing an aggregate command, the event it emits, and its destination state must receive a complete breaking-change report and a replay-audit target from `keiro-dsl diff --since REF`. Today both source revisions can pass `check`, yet the diff aborts with an output-resolution error and writes neither requested report. After this change, the command still exits nonzero when its normal compatibility gate finds a break, but it first explains the removed declarations and writes valid compatibility and replay-impact JSON.

This implements [IR-50](../improvement-requests/classify-removal-of-a-command-together-with-its-emitted-event-in-keiro-dsl-diff.md), reproduced during the review of `keiro-dsl-0.20.0.0` through `a0c82a42`. The separate parser corrections are owned by [ExecPlan 313](313-fix-contract-parser-nominal-names-and-case-sensitive-list-syntax.md). They have no implementation dependency on this work. This plan does not authorize deployment, history deletion, or acceptance of the breaking removal by a consumer.

## Progress


- [ ] M1: Add independently valid old/new Language 6 removal fixtures and failing library, single-source CLI, and workspace CLI regressions.
- [ ] M2: Replace mixed-revision fold resolution with sound comparison of separately resolved evidence while retaining replay-impact precision and frozen fold bytes.
- [ ] M3: Verify complete classification/report emission, document the correction, reconcile IR-50, and run the DSL/corpus/documentation gates.

## Surprises & Discoveries


None recorded during implementation yet.

## Decision Log


2026-10-14: Treat IR-50 as a comparison defect, not a reason to forbid valid source evolution or suppress a breaking verdict. A nonzero compatibility-gate exit with complete reports is success for the removal regression; an early resolution failure is not.

2026-10-14: Resolve every real aggregate only against its own checked service. Do not catch a fold error and invent `ReplayNeutral`, copy deleted declarations into the candidate, or discard failed canonical segments. Preserve full semantic failure reporting for genuinely invalid inputs.

2026-10-14: Preserve canonical fold bytes and existing replay-impact/report interfaces. Comparison-only evidence may be refactored internally, but this reporting repair must not invalidate consumer snapshots or broaden all additions and safe guard changes into replay-affected changes.

2026-10-14: Keep one dedicated intention and plan for IR-50, independent of the parser plan, as requested by the user.

## Outcomes & Retrospective


Not implemented. Record the observed before/after reports and checks here when the milestones complete. Do not mark IR-50 completed on the strength of creating this plan.

## Context and Orientation


Work from `/Users/shinzui/Keikaku/bokuno/keiro`. An aggregate is a state machine with commands, emitted events, control states, and registers. Replay reconstructs its state by interpreting stored events. A fold surface is the canonical text describing that interpretation; its digest identifies snapshot compatibility. A replay-impact report selects aggregate event types and whether to include streams with snapshots for a later audit; it does not itself inspect a database or prove historical safety.

`keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` pairs a normalized source graph with its language/runtime contract in `CheckedService`. `keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs` resolves an aggregate against that service and returns either canonical text or `FoldSurfaceError`. Resolution includes register types and initials, nominal identity, nominal equality used by guards, referenced rules, and event-output ownership. `eventOutputMappingFromGraph` in `keiro-dsl/src/Keiro/Dsl/EventOutput.hs` needs the actual command/event declarations for a transition.

`keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` first validates the full fold surface of both revisions in `replayImpactServices`. However, `matchedAggregateImpact` then constructs `replaceAggregateTransitions oldAggregate.transitions newAggregate` and resolves that hybrid against `newService`. A removed old transition consequently refers to commands, events, or state-dependent expressions that the new declaration set no longer contains. The operation intended to isolate non-transition changes is not a valid semantic graph.

`keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs` supplies duplicate-aware, order-independent transition and replay-body comparisons. `changedTransitionEvents` in `ReplayImpact.hs` uses them to preserve precision: additions are normally replay-neutral, while changed/removed old bodies select affected event types. Guard loosening, equivalent split/merged unions, replay-only edges, and no-emission edges already have distinct treatment. Retain that behavior. `decodeSurfaceAffected` and `mappedRegisterSurface` separately identify decoder and register dependencies.

`keiro-dsl/src/Keiro/Dsl/Diff.hs` owns `diffServices`, `removedEvents`, `guardTighteningDiff`, and `transitionSurfaceDiff`. Existing event removal reports `EvtRemovedNotDeprecated`; changed folds report `AggFoldSurfaceChanged`. The CLI in `keiro-dsl/app/Main.hs` combines ordinary diff and replay impact before writing reports, for both the `run (Diff ...)` branch and `runWorkspaceDiff`. Thus a failure in replay-impact analysis prevents otherwise available compatibility findings from being delivered. Workspace comparison reconstructs historical members from Git; it must work even when a removed member no longer exists on disk.

Tests belong in `keiro-dsl/test/Main.hs`, especially the `replay impact`, diff, and CLI/workspace groups. The complete canonical fold goldens and frontend compatibility tests protect identity. Fixtures live in `keiro-dsl/test/fixtures/`, with package test discovery and packaging inventories that must remain consistent.

[ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) assigns cross-revision hazards to diff and fixes the compatibility-vector, report, and replay-audit contracts. [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md) requires total resolution, frozen canonical encoding, own-service analyses, and order-independent replay comparisons. [ADR-16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) preserves language provenance at the checked-service boundary. [ADR-49](../adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md) scopes new positive tests to Language 6; the separately planned support cutoff is not part of this fix. These decisions mean a valid removal must be classified without rewriting either source or claiming its data migration is safe.

## Plan of Work


### Milestone 1: Reproduce the failure with valid source pairs


Add `keiro-dsl/test/fixtures/ir50-removal-old.keiro` and `keiro-dsl/test/fixtures/ir50-removal-new.keiro` using the minimal sources in Concrete Steps. Assert that each parses, validates, and resolves its complete own-service fold successfully. Assert `diffServices` returns the breaking event finding and that `replayImpactServices` returns `Right (ReplayAffected ...)`, not `FoldEventOutputResolutionFailed`. Include a variant that removes a command/event while retaining both states, so dependency removal is tested independently of control-state changes.

Add a focused `IR-50 removal diff` test group. Reuse the existing temporary Git repository and `runKeiroDsl` helpers to commit only the old fixture, write the new source in the working tree, and invoke `diff --since HEAD` with both output paths. The expected exit is 1 from the breaking gate, with a `BREAKING` headline and two parseable reports. Assert the old source and Git history are unchanged by diff. Repeat through a workspace with an aggregate member, including historical member loading when a declaration/member is removed. Do not use the project working tree as a test Git repository.

Also add controls for unchanged specs, a purely additive event/transition, a command/event rename, whole-aggregate removal, same-state command/event removal, and genuinely invalid old and new graphs. On the initial implementation, the valid combined removal must fail specifically with `OutputEventMissing`, while the individual checks succeed. Existing narrow replay and guard tests are the regression baseline for M2.

### Milestone 2: Compare resolved evidence without mixing revisions


Remove the hybrid resolution from `matchedAggregateImpact`. Introduce an internal comparison projection of fold evidence that is resolved independently for each real aggregate/service pair. Factor reusable construction out of `FoldFingerprint.hs` if needed, rather than parsing serialized canonical text or implementing a second inconsistent resolver. The full fold renderer must concatenate exactly the existing segments in exactly the existing order, yielding byte-identical surfaces and hashes for every unchanged spec.

Separate aggregate-wide evidence (runtime fold segments, control-state layout, register types/initials, and their mapped/nominal dependencies) from transition-associated evidence (resolved output mappings, referenced-rule closure, and nominal equality contracts used by guards). Associate transition evidence with the existing transition-family/replay-body comparison identities. Resolve references on each side before matching. A removed body needs only its old resolved evidence; a new body needs only its new evidence. Neither requires evaluating the other revision's syntax against local declarations.

Use `changedTransitionEvents` for changes in transition structure and guard coverage, and `decodeSurfaceAffected` for removed/retyped event payloads. Compare dependencies of retained historical bodies so a changed referenced rule, nominal equality policy, mapped/nominal binding, or output ownership cannot become falsely neutral merely because source transition text is unchanged. Ignore dependencies introduced only by genuinely new bodies when they cannot affect prior history. Aggregate-wide changes may conservatively select every old event and snapshot-bearing stream; local body changes must retain the existing narrower behavior where the current tests promise it. If a dependency change cannot be precisely attributed, select a conservative affected set and document that case instead of returning neutral.

Before integrating, pin this projection with tests for referenced rule changes, nominal admission/equality changes, mapped register changes, output-ownership changes, removed type declarations used only by removed events, additions, guard loosening, equivalent split/merged guards, and transition declaration permutations. A naive empty-transition projection loses rule/equality dependencies, while a naive full-fingerprint inequality over-reports additions and safe guard edits; neither is an acceptable repair. Preserve the up-front resolution of both complete real graphs so genuinely malformed graphs still return errors. Keep comparison data internal unless an existing module boundary forces an explicitly reviewed API addition.

In `Diff.hs`, ensure the successful removal report names the event, removed command, and removed state required by IR-50. Retain `EvtRemovedNotDeprecated` as the breaking decoder finding. Enrich the existing fold-change finding with deterministic, sorted removed-command/state details if existing output does not identify them; do not invent duplicate breaking findings solely to repeat these names. A replay-only remedy whose required declarations were deleted must remain unavailable rather than printing an uncompilable suggested transition. Extend `DiffReport.hs` only if necessary to carry the same evidence through the existing schema without replacing current fields.

### Milestone 3: Prove report delivery and close the request


Confirm the single-source and workspace CLI paths both write compatibility and replay-impact files before returning the normal failing gate status. Keep current JSON schema identifiers, open diagnostic-code behavior, sorted event arrays, and report compatibility vectors. The combined-removal report must identify `RetiredEvent` as no longer decodable, name `Retire` and `Retired`, and select aggregate `Example` with snapshot inclusion. The state-preserving variant must include the removed event; unchanged event types should not be added merely to mask an unresolved cross-revision reference.

Run the focused and full checks below and inspect canonical fold goldens and generated corpus diffs for unintended churn. Update `keiro-dsl/CHANGELOG.md` and `docs/user/keiro-dsl-validation-and-evolution.md` to describe complete reports for removals, including the expected nonzero gate status. Link this plan from the IR-50 document and mark that request completed only after all acceptance checks pass. Follow the improvement-request bundle's metadata and log conventions when changing its status. Distill the own-revision evidence rule into ADR-18 (and ADR-4 if report guidance changes), preserving document IDs and updating the ADR log through the repository's OKF workflow. Record validation evidence in this plan.

## Concrete Steps


Use the repository root and Nix development shell for all verification:

```bash
nix develop -c z3 --version
nix develop -c cabal test keiro-dsl-test --test-show-details=direct --test-options='--match "IR-50 removal diff"'
nix develop -c cabal test keiro-dsl-test --test-show-details=direct --test-options='--match "replay impact"'
```

The old fixture is:

```keiro
language keiro-dsl 6
context retirement
aggregate Example
  regs
  states Active Retired
  command Keep { note:Text }
  command Retire { note:Text }
  event Kept = fields(Keep)
  event RetiredEvent = fields(Retire)
  Active -- Keep --> emit Kept ; goto Active
  Active -- Retire --> emit RetiredEvent ; goto Retired
```

The new fixture is:

```keiro
language keiro-dsl 6
context retirement
aggregate Example
  regs
  states Active
  command Keep { note:Text }
  event Kept = fields(Keep)
  Active -- Keep --> emit Kept ; goto Active
```

For a manual isolated reproduction after adding those fixtures, build the executable and run this from the repository root. The Python program inherits the Nix environment, creates its own temporary Git repository, and does not commit to the project branch:

```bash
nix develop -c cabal build keiro-dsl:exe:keiro-dsl
nix develop -c python3 - <<'PYPROBE'
from pathlib import Path
import json
import subprocess
import tempfile
repo = Path.cwd()
cli = subprocess.check_output(['cabal', 'list-bin', 'keiro-dsl:exe:keiro-dsl'], text=True).strip()
work = Path(tempfile.mkdtemp(prefix='keiro-ir50-'))
def run(*args):
    result = subprocess.run(args, cwd=work, text=True, capture_output=True)
    print(result.returncode, result.stdout, result.stderr)
    return result
run('git', 'init', '-q')
source = work / 'service.keiro'
fixtures = repo / 'keiro-dsl/test/fixtures'
source.write_text((fixtures / 'ir50-removal-old.keiro').read_text())
assert run(cli, 'check', 'service.keiro').returncode == 0
run('git', 'add', 'service.keiro')
assert run('git', '-c', 'user.name=IR50 Probe', '-c', 'user.email=probe@example.invalid',
           '-c', 'commit.gpgsign=false', 'commit', '-qm', 'test: record removal baseline').returncode == 0
source.write_text((fixtures / 'ir50-removal-new.keiro').read_text())
assert run(cli, 'check', 'service.keiro').returncode == 0
result = run(cli, 'diff', 'service.keiro', '--since', 'HEAD', '--explain',
             '--report-out', 'diff.json', '--replay-impact-out', 'replay.json')
assert result.returncode == 1
assert 'OutputEventMissing' not in result.stdout + result.stderr
report = json.loads((work / 'diff.json').read_text())
impact = json.loads((work / 'replay.json').read_text())
assert 'EvtRemovedNotDeprecated' in json.dumps(report)
assert impact['verdict'] == 'affected'
assert 'RetiredEvent' in impact['aggregates']['Example']['eventTypes']
assert impact['aggregates']['Example']['includeSnapshotStreams'] is True
print('PASS: breaking removal produced both reports', work)
PYPROBE
```

Before the fix, the diff emits this error and the report files are absent:

```text
aggregate fold output resolution failed for 'Example.Retire' emitting 'RetiredEvent': OutputEventMissing "RetiredEvent"
```

After the fix, expect a breaking event-removal finding, declaration-removal details, an affected replay target, exit 1, and both JSON files. The exact full affected-event set for the state-removing example may conservatively include `Kept` because the control-state layout changed; assert an exact narrow set separately for the state-preserving fixture.

Finish with:

```bash
nix develop -c cabal test keiro-dsl:tests --test-show-details=direct
nix develop -c just dsl-api-boundaries record-migration-policy conformance-corpus-policy
nix develop -c just adr-validate user-documentation-validate
git diff --check
```

Use the repository's improvement-request profile/log validation if its metadata is changed; discover the current descriptor from `mori show --full` rather than guessing. Commit implementation increments with Conventional Commits and these trailers:

```text
ExecPlan: docs/plans/314-fix-ir-50-command-and-event-removal-diff-classification.md
Intention: intention_01m4xaptn7exgbtwqm4ej06fye
```

## Validation and Acceptance


The valid old and new fixtures must each pass `check` and independent fold resolution. Their comparison must return ordinary findings and a non-neutral replay result; CLI exit 1 must be attributable to the breaking gate with both complete reports present. Single-source and workspace results must agree on aggregate/event impact. The report must name the removed command, event, and state, retain the breaking historical-reader verdict, and explain why a replay-only remedy cannot be pasted when its declarations are gone.

Unchanged specs remain neutral. Additive event/transition changes remain neutral wherever they were previously neutral. Existing guard loosening, split/merge, duplicate cancellation, declaration-order, and narrow guard-impact tests pass unchanged. Removed declarations cannot hide simultaneous rule, binding, nominal-domain, register, or output-ownership changes. Invalid real input graphs still fail explicitly and produce no misleading successful/neutral report. A separately valid removal must not be handled by suppressing a resolution error.

Canonical fold text, digests, generated runtime modules, snapshot identity, and report schemas remain stable for unchanged inputs. New tests are Language 6 tests. The full DSL suite, fixture/corpus inventory, and documentation gates pass, with actual results recorded before IR-50 is completed.

## Idempotence and Recovery


Diff and report generation read Git history and source; they do not modify either. Manual probes use fresh temporary repositories and output files. Keep breaking-source probes out of the main checkout's Git history. If an internal fold refactor changes canonical goldens, stop and restore the exact renderer before proceeding; do not refresh goldens to bless a reporting-only identity change. Retain failed regression cases while reverting only unsuccessful implementation edits. Do not implement a fallback that changes failure into replay neutrality. No database or production state is needed for this static comparison repair.

## Interfaces and Dependencies


Retain `replayImpactServices :: CheckedService -> CheckedService -> Either FoldSurfaceError ReplayImpact`, the `ReplayImpact`/`AggregateImpact` public shapes, and `aggregateFoldSurfaceForService`/`aggregateFoldFingerprintForService`. An internal evidence projection should be shared with the existing fold resolver and respect the cached type graph on its own `CheckedService`; it must not attach one revision's graph to another revision's declarations. Existing `TransitionFamily` comparison is the authority for transition matching. The CLI retains the current flags and gated exit behavior.

No external library or dependency upgrade is expected. If dependency source is needed, locate it through Mori before relying on its API, and verify any proposed bounds against the authoritative package registry and upstream tags. Never traverse `/nix/store` or the filesystem root. This plan changes comparison/reporting only and does not add a reader, migration, or rollout bypass.

Creation note (2026-10-14): Authored from the reproduced IR-50 failure, the replay/fold/diff implementation, existing precision tests, and ADRs. Implementation remains pending under the linked intention.
