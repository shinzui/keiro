---
id: 323
slug: list-mounted-process-managers-without-runtime-performance-regressions
title: "List mounted process managers without runtime performance regressions"
kind: exec-plan
created_at: 2026-10-26T19:13:39Z
intention: "intention_01m5wt12qte7wrtk3r031syktj"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-26T19:13:39Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-26T19:26:00Z
      mode: "implement"
      note: "Establish implementation baseline and implement mounted manager discovery with performance evidence"
---

# List mounted process managers without runtime performance regressions

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current during implementation. Creation of this plan does
not implement the feature or establish performance acceptance.


## Purpose / Big Picture


Implement [IR-56](../improvement-requests/list-mounted-process-managers-over-the-ops-surface.md):
operators and clients can discover the process managers mounted by an application through
`pm types` and `GET /pm/types`, without knowing a manager name first. A process manager
coordinates reactions to input events; its journal records its persisted state. A mounted
inspector is an application-supplied description of how to inspect that manager. Discovery
lists these descriptions, including managers with no persisted instances.

The user requires no performance regression. Enumeration must use static in-memory metadata,
with no journal, instance, snapshot, or timer queries and no changes to ordinary command or
worker processing. HTTP retains its existing schema checks and resource limits. Completion
requires both structural evidence of isolation and measured evidence under active polling;
read-only code alone does not establish isolation. UI changes and publication are outside
this plan.


## Progress


- [ ] Milestone 1: Record reproducible pre-change performance controls and a comparable measurement protocol.
- [x] Milestone 2 (2026-10-26): Deterministic metadata summaries and embedded `pm types` pass all 786 core and 55 ops tests in Nix, including aliases, all inspector families/policies, forced callback sentinels, and an armed store-access sentinel. Evidence: `keiro/bench/results/pm-types/candidate-tests-final.log`.
- [x] Milestone 3 (2026-10-26): The representative Jitsurei CLI/HTTP path and all 53 HTTP tests pass in Nix, including missing/empty hooks, response limits, fresh schema refusal and verifier-only pool use. Jitsurei's 25 tests also pass; evidence is in `keiro/bench/results/pm-types/candidate-tests-final.log`.
- [ ] Milestone 4: Demonstrate no measurable runtime regression, pass the repository gates, and document the shipped interface and evidence.

Implementation started 2026-10-26 from `d61aabcfdaa4af14aef59712f10deb4826f0e99b`,
preserved in detached `../keiro-pm-types-baseline`. The full pre-change Nix build
passed. Five durable saturation and five mounted-idle controls are retained under
`keiro/bench/results/pm-types/`. The pre-change six-guard run passed five guards
but failed read-model; its focused repeat also fails, on different cases. These
red controls leave baseline/release acceptance unresolved. The fixed offered rate
is 50 operations/second against measured median capacity 718.89 operations/second.
The discovery implementation and all four focused suites pass (919 examples);
matched performance evidence and the final gate remain underway. Preserve unrelated concurrent plans
and documentation commits.

The first complete 60-trial cohort (`matched-v1`) is red: 1,000-descriptor polling
raises writer p99 by a paired median 5.195% (95% interval +1.019% to +8.993%)
against its matching idle control, with a supported +0.0091% writer-allocation
increase. Single-manager active/idle comparisons pass, but baseline/same-source
uncertainty remains unresolved. A direct-encoding implementation is now under
final validation; the initial source/measurements remain retained. No performance
milestone is accepted from the new implementation until new paired evidence passes.


## Surprises & Discoveries


2026-10-26: Pre-change mounted-idle p95 varies from 7,428 to 8,792 microseconds
across five 20-second trials, although throughput remains 50.025–50.040 operations
per second. This is existing measurement noise, not candidate evidence, and may
prevent the required 1% resolution. Keep raw controls and investigate paired
uncertainty rather than interpreting paced throughput as unchanged capacity.

2026-10-26: Source inspection of `mori://hasql/hasql/packages/hasql-pool`
shows that releasing a pool resets connections and leaves it usable. The direct
handler test instead uses a throwing connection observer, checks that an actual
store read throws, and then fully renders discovery output using that valid store
handle. A released-pool sentinel would not prove the intended zero-access boundary.

2026-10-26: The pre-change read-model guard is red before discovery is added:
the full run fails `serving-binding/versioned-three` at the historical 25%
ceiling; a focused repeat fails `legacy-three` (+30%) and `repair/100` (+38%).
Both logs are retained under `keiro/bench/results/pm-types/`. Continue the
functional implementation and collect attributable measurements, but do not
change historical CSVs or claim baseline/release acceptance from these results.

2026-10-26: The optimized custom-policy sentinel initially returned `never`
instead of `custom`, while an interpreted probe reported `custom`. A minimized
compiled probe confirmed that the packed descriptor still carried `Custom`; the
summary's fused constructor match was the divergent boundary. Field optics,
direct selectors, explicit record patterns, an opaque throwing callback and
`NOINLINE listProcessManagerTypes` did not fix it. A private `OPAQUE policyLabel`
does: the original optimized core test now passes. Retain this boundary and the
executable regression test; no command/snapshot runtime implementation or
dependency pin changes. The package registry lists GHC 9.14.1 as newer, and the
GHC 9.12.4 release tag is `1b7c33460847bb8017142407b853811fd8d04bff`;
the project remains on its verified Nix compiler rather than upgrading scope.

2026-10-26: Allocation attribution identifies roughly 136 KB of summary work,
1.073 MB of JSON-tree construction and 3.507 MB of generic encoding per
1,000-descriptor response. The on-demand direct encoder uses 2.643 MB for encoding,
plus the same summary work, about 41% less than the original pipeline. The real
first cohort adds about 390 MB of process allocation across 80 large polls;
process bytes are diagnostic, while its writer p99/allocation regressions block
acceptance. A fixed encoded-key experiment increases allocation and is rejected;
retain its patch and profile as failed evidence.

2026-10-26: The existing benchmark stopped its throughput clock after joining the
external poller. This charged client cleanup to writer throughput (including a
supported +0.0031% apparent slowdown in a single-manager/pre-change comparison).
The candidate now stops at writer completion, records client cleanup separately,
and retains GC count/time diagnostics. Its per-operation p95/p99 samples and writer
work are unchanged. The old baseline has no poller in the compared disabled/idle
modes, so its original completion clock incurs no external-client cleanup.

## Decision Log


2026-10-26: Enumerate the existing `ProcessManagerInspectors` map on demand. Do not add a
runtime registry, background refresh, descriptor cache, new descriptor fields, or database
index. The catalog already contains the metadata needed for discovery, and extra machinery
would introduce costs and compatibility obligations unrelated to IR-56.

2026-10-26: Use implementation baseline `d61aabcf`, rather than the creation
commit, for the detached executable and all pre-change controls. Concurrent
documentation-only commits do not change its production sources. Preserve those
unrelated commits and new plans, and record the exact final candidate identity
separately.

2026-10-26: Replace the assumption of no HTTP production edits with a bounded
direct-encoding path, required by the measured large-catalog interference.
The owning summary type supplies equivalent Aeson `Value` and `Encoding` forms;
an Encoding describes JSON bytes directly without first materializing a JSON tree.
Ops prepares both from the same on-demand summary list. Its canonical array remains
deferred when HTTP consumes the direct form. The transport supplies its existing
byte/deadline-bound encoder through `runCommandWithReadEncoding`; existing command
and workflow-header paths delegate unchanged. Nothing caches descriptors or response
bytes, and route grammar, schema verification, admission and delivery limits stay
unchanged. JSON parity, cap refusal and repeated fresh encoding/schema work are
executable acceptance checks. This changes implementation approach, not the no-regression
acceptance requirement.

2026-10-26: Correct the controller's classification of noisy point estimates.
Its initial extra condition refused every median above equality even when the
95% interval included equality and excluded a 1% degradation. The plan requires
supported degradation and reproducible adverse trends, so retain the point
estimate/sign counts for review and apply the stated interval rule. The zero
supported-slowdown threshold and 1% uncertainty ceiling are unchanged. An added
noise control passes while the supported 0.1% negative control still fails; the
first cohort's supported large-catalog regressions remain red under this rule.

2026-10-26: Return the catalog key as `name`, because it is the value accepted by the existing
`pm show --name` and `pm list --name` lookup. The public map currently permits aliases that
differ from `inspector.name`; discovery must return a usable lookup name. Preserve ascending
map-key order and include an alias test. Do not change existing instance-view naming.

2026-10-26: Report snapshot configuration from the existing event-stream descriptor and
`timers_configured: null`. No timer capability declaration exists in the current inspector.
Unknown is distinct from false and from the number of pending timers. Do not evaluate a
reaction function or inspect stored instances to infer capabilities.

2026-10-26: Treat any reproducible runtime degradation as blocking, even below historical
thresholds. Existing gates remain mandatory but cannot alone satisfy the user's stronger
constraint. Measurements have finite resolution; document that resolution and never claim
mathematical proof of exactly zero cost from noisy timings.


## Outcomes & Retrospective



## Context and Orientation


The creation baseline is commit `e1d45f21d544178023ca953c91af4986afd40f08`. At creation,
`docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md` had an
existing modification and `docs/plans/322-support-exact-equality-guards-for-mapped-structural-enums.md`
was untracked. Preserve unrelated work. This is a standalone follow-up to IR-56, with its own
user-requested intention, rather than a new child or edit to MasterPlan 45. Recheck the exact
implementation baseline before collecting evidence if source has moved.

`keiro/src/Keiro/ProcessManager/Inspect.hs` defines `ProcessManagerInspector`, its three
constructors for legacy, domain, and reactive managers, and `ProcessManagerInspectors`, a
`Map Text SomeProcessManagerInspector`. The wrapper allows differently typed managers in
one catalog. Descriptors carry `name`, `category`, `eventStream`, stream membership functions,
state display functions, and provenance mode. They do not carry timer capability metadata.
The event-stream descriptor already has `stateCodec` and `snapshotPolicy`. Inspecting whether
a codec is present requires no state encoding or state-machine traversal.

`keiro/src/Keiro/Inspection/Aggregate.hs` provides the model: `AggregateTypeSummary`,
`listAggregateTypes`, and `aggregateTypeJson`. Its `snapshots_configured` means that a state
codec is configured, not that any snapshot exists; `snapshot_policy` distinguishes `never`,
`every:N`, `on_terminal`, and `custom`. A custom policy's function is not executed to name it.

`keiro-ops/src/Keiro/Ops/ProcessManager.hs` currently has only `Show` and `List`, and its runner
performs a manager-name lookup before dispatch. `keiro-ops/src/Keiro/Ops/Aggregate.hs` already
has `Types` with an `items` JSON envelope. `keiro-ops/src/Keiro/Ops/Embed.hs` owns
`AppHooks.processManagers :: Maybe ProcessManagerInspectors`.
`keiro-ops/src/Keiro/Ops.hs` mounts the `pm` command only when that field is `Just`, validates
commands, and dispatches to the manager runner. `Nothing` and `Just Map.empty` are different:
the former omits the command; the latter mounts a valid empty catalog.

`keiro-ops-http/src/Keiro/Ops/Http/Route.hs` derives HTTP commands from the CLI parser.
`keiro-ops-http/src/Keiro/Ops/Http/Application.hs` handles parsing, admission, per-request
schema verification, execution, and bounded response encoding. Routes still derive from the
command tree. Measured large-catalog allocation requires a small production encoding change:
`Keiro.Ops.runCommandWithReadEncoding` receives the host's bounded encoder, delegates existing
commands to the existing runner, and prepares manager types on demand. `encodeBoundedEncoding`
in `keiro-ops-http/src/Keiro/Ops/Http/Budget.hs` shares the ordinary byte-boundary implementation.
No schema check, cache, route table or resource policy is bypassed. A metadata-only handler still incurs the
transport's existing schema check; claiming the whole HTTP request performs zero SQL would
be incorrect. `keiro-ops/src/Keiro/Ops/Render.hs` renders the same `OpsResult.jsonValue` for CLI
JSON mode. Human output uses its column headers and rows.

`jitsurei/src/Jitsurei/Inspection.hs` exports `jitsureiProcessManagerInspectors`, containing
`jitsurei-fulfillment`. `jitsurei/src/Jitsurei/FulfillmentProcess.hs` defines category
`fulfillment`, snapshot policy `Never`, and no state codec. `jitsurei/app/Main.hs` mounts it
for `jitsurei-demo ops`. The Jitsurei library has no dependency on `keiro-ops-http`, so HTTP
tests may depend on that local library without a library dependency cycle.

Relevant ADRs were discovered by scanning local filenames and headings. [ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
requires ops adapters over supported library APIs and explicit application hooks.
[ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
requires bounded inspection, no diagnostic work on ordinary runtime paths, and measured
interference. [ADR-53](../adr/0053-the-http-operational-surface-is-a-transport-over-the-ops-command-tree.md)
requires shared CLI/HTTP grammar, fresh schema agreement, bounded admission and delivery,
and no polling task on mount. [ADR-54](../adr/0054-aggregate-inspection-reuses-hydration-without-diagnostics-on-the-command-path.md)
keeps application descriptors and presentation separate from command execution.
[ADR-55](../adr/0055-legacy-reaction-provenance-is-bounded-explicit-opt-in-metadata.md)
requires honest unavailable evidence and preserves default-off reaction costs.
[ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md)
requires attributable, fixed-workload benchmarks and the complete release gate; failed or
inconclusive measurements are not acceptance. This plan adopts those constraints and tightens
performance acceptance to the user's no-regression requirement.


## Plan of Work


### Milestone 1: Establish comparable performance controls


Before changing production code, record the exact source tree, compiler, optimization,
RTS options, database version/settings, fixture sizes, and machine in
`keiro/bench/results/pm-types/README.md`. Preserve raw measurements in separate baseline and
candidate subdirectories. Build before measuring and run on a quiet machine, serially, in
`nix develop`. Use normal durable PostgreSQL settings and autovacuum. Do not borrow a
production database; the existing benchmark support creates disposable migrated fixtures.

Use `keiro-ops-http/bench/InspectionInterference.hs` for disabled and mounted-idle controls.
It measures real workflow/timer writer work, writer-thread allocations, latencies, and
throughput. Its current active modes poll workflow headers and feeds with empty hooks;
they do not exercise manager discovery. Do not cite them as `/pm/types` evidence. Capture
saturation to select a fixed offered rate comfortably below baseline capacity, and retain
same-source repeated controls to characterize measurement noise. Independently record the
existing command benchmark subset and all six guard results. This milestone is accepted when
the pre-change controls are reproducible and the exact matched commands/settings are recorded,
before interpreting candidate timings.

Prepare a small orchestration script, `scripts/measure-pm-types.sh`, that runs already-built
baseline and candidate benchmark executables serially, alternates their order across at least
five pairs, and retains every trial. Its interface is `BASELINE_BINARY CANDIDATE_BINARY
OUTPUT_DIRECTORY OPS_PER_SECOND`. Binary arguments are explicit paths obtained from
`cabal list-bin`; the script must execute them, never traverse their directories. Keep the
baseline in a detached worktree at the recorded commit when implementation begins; do not
create a feature branch or reset the working tree. Use distinct build directories. The script
must identify unavailable modes and fail on command failures, missing samples, or lost load,
rather than emit a successful comparison of partial data.

### Milestone 2: Add pure discovery and CLI rendering


In `keiro/src/Keiro/ProcessManager/Inspect.hs`, add and export `ProcessManagerTypeSummary`,
`listProcessManagerTypes`, and `processManagerTypeJson` with the interface specified below.
Traverse `Map.toAscList` once, use the key for the public name, `categoryText inspector.category`
for the category, and inspect only the event-stream's codec presence and policy constructor.
Keep the policy-label mapping local or reuse an already-public helper; do not refactor
runtime hydration or broaden this change into an aggregate refactoring.

In `keiro-ops/src/Keiro/Ops/ProcessManager.hs`, add a nullary `Types` command, a `types`
subcommand with no options, and `validateCommand Types = Right ()`. Keep every manager read
non-mutating. Dispatch `Types` before any owner-name lookup. Retain the current named paths
for `Show` and `List`, including their validation and failures. Bind the summary list once and
reuse it for human rows and JSON. Use columns `name`, `category`, `snapshots_configured`,
`snapshot_policy`, and `timers_configured`; render unknown timers as `unknown` in the table.
Do not alter `AppHooks` or any existing inspector constructor signature.

Give `ProcessManagerTypeSummary` an explicit `ToJSON` instance whose canonical value
delegates to `processManagerTypeJson` and whose direct encoding writes the same fields.
`prepareTypes` in the owning ops module returns the unchanged `OpsResult` shape and
the equivalent direct encoding from one summary binding. Defer the canonical JSON
array using a lazy map value, so the direct HTTP path does not construct an unused
JSON tree. Both representations must remain fully forceable and equal, including
escaped names, null/known timers and all policy constructors. `runCommandWithReadEncoding`
invokes the host encoder afresh on each types request and never inserts a metadata
entry into the existing header cache.

Extend the process-manager inspection tests in `keiro/test/Main.hs` and CLI coverage in
`keiro-ops/test/Main.hs` (with `keiro-ops/test/ReactionInspectionSpec.hs` for the existing modern
fixture). Verify empty, multiple, aliased, legacy, domain, and reactive descriptors, known
snapshot configuration, and unknown timers. Use functions that throw if invoked as display,
stream resolution, membership, enabled-input, and custom-policy callbacks. Fully force the
summary JSON and human output so laziness cannot conceal callback execution. Invoke the direct
`Types` handler with an unusable store sentinel in an otherwise valid `OpsEnv`, and force its
result: it must succeed without touching that store. Test actual parsing with missing hooks,
empty hooks, and populated hooks, and test that `--name` is neither required nor accepted by
`types`. Existing `show`/`list` tests must continue passing. Acceptance is a working CLI result
and proof that discovery does not need a store or evaluate instance callbacks.

### Milestone 3: Verify the HTTP consumer with real application metadata


Add local `jitsurei` to the HTTP test component's dependencies in
`keiro-ops-http/keiro-ops-http.cabal`, not to the production library. In
`keiro-ops-http/test/Main.hs`, mount `Ops.emptyAppHooks` updated with
`processManagers = Just jitsureiProcessManagerInspectors` into a real `opsApplication` over a
fresh migrated test store. Exercise `GET /pm/types` through the existing WAI request helpers
and compare its JSON with the parsed CLI command's runner result. Do this representative path
early, before expanding the boundary cases. The exact Jitsurei row below must be returned even
with no journal instances seeded.

Verify `Nothing` yields HTTP 400 `invalid_request`, matching `/pm/list` without hooks;
`Just Map.empty` yields HTTP 200 with `{"items":[]}`. Verify `--name`-equivalent query options
are rejected, and POST uses the existing read-command method policy. Prove the path still
refuses schema drift and honors the response-byte limit with an oversized synthetic catalog.
Use existing pool-observation helpers to show rejected parsing does no schema work and a
successful discovery performs only the existing verifier work, with no manager data reads.
Compare with `/aggregate/types` on the same fixture instead of hard-coding incidental verifier
query counts. Existing admission, timeout, delivery, and CLI/HTTP route tests remain required.

Acceptance includes the Jitsurei row, identical CLI/HTTP JSON, empty versus absent hook behavior,
and unchanged transport policies, all through the production command tree and handler.

### Milestone 4: Close performance evidence and documentation


Extend `keiro-ops-http/bench/InspectionInterference.hs` with `pm-types-idle`, `pm-types`, and
`pm-types-many` modes, mounting Jitsurei's catalog or a deterministic 1,000-entry catalog of
aliases of that descriptor. Add Jitsurei only to the benchmark component dependencies. Keep
existing modes and writer work unchanged. Extend `keiro-ops-http/bench/InspectionClients.hs`
with an HTTP-only branch for these modes: no WebSocket startup or header warm-up. Warm
`/keiro/pm/types`, then poll it from four staggered clients at one request per second each
through the real mounted server and separate inspection pool. Validate expected item counts
and fields, count successful requests separately from rejections, and fail if the intended
load disappears. Add a matching `pm-types-many-idle` control for the large catalog. The
orchestration script runs these candidate modes paired with their candidate idle controls.

The old binary has no successful `/pm/types` route. Never compare its 400 responses with
candidate 200 responses as equivalent work. Baseline/candidate disabled and existing idle
modes isolate code-change effects. Candidate catalog-mounted idle/active pairs, plus the
pre-change idle writer reference, measure the incremental effect of successful new polling.
Record both comparisons explicitly. Add a saturation comparison for disabled code paths to
avoid mistaking fixed offered-load throughput for available capacity. Preserve existing
route/command guard results as additional regression coverage.

Use the performance acceptance rules below, including writer-thread rather than combined
allocation, raw paired samples, and uncertainty. Add a bounded retention run for each new
active catalog size, sampling post-major-GC live heap and active threads over at least 60
seconds and checking cleanup. There must be no growing per-request registry or abandoned
client/server work. Catalog enumeration and serialization may scale with the number and
encoded size of mounted descriptors, never with the number of journal instances or events.

Update `docs/guides/serve-keiro-ops-over-http.md` with adjacent aggregate-types and manager-types
examples; at plan creation it has no dedicated `/aggregate/types` JSON example, so add both
rather than assume one exists. Explain mounting, unknown timers, codec presence versus stored
snapshots, sorted lookup names, the empty/missing distinction, and the normal schema check.
Add relevant entries to `keiro/CHANGELOG.md`, `keiro-ops/CHANGELOG.md`, and
`keiro-ops-http/CHANGELOG.md`. Update IR-56's implementation status only after its acceptance
passes, respecting its bundle metadata/log conventions and distinguishing implementation from
publication. Review the plan's durable decisions for an ADR-53/ADR-55 amendment; follow
`agents/skills/exec-plan/ADR.md` and inspect `mori show --full` and the declared profile before
any ADR edit. Do not publish a release or change the UI as part of this plan.


## Concrete Steps


Run all commands from the repository root. Verification and benchmarks run inside Nix.
Start with these controls, recording output under the milestone 1 evidence directory:

```bash
nix develop -c cabal build all --enable-tests --enable-benchmarks
nix develop -c cabal bench inspection-interference --benchmark-options='--output bench/results/pm-types/baseline-capacity --rate saturation --trials 5 --mode disabled +RTS -N2 -T -RTS'
nix develop -c cabal bench inspection-interference --benchmark-options='--output bench/results/pm-types/baseline-idle --rate 50 --trials 5 --mode idle +RTS -N2 -T -RTS'
nix develop -c just bench-regression
```

When implementation begins, preserve the source used for those controls in a detached
checkout. If the recorded creation commit is still the implementation baseline, run:

```bash
git worktree add --detach ../keiro-pm-types-baseline e1d45f21d544178023ca953c91af4986afd40f08
cd ../keiro-pm-types-baseline
nix develop -c cabal build bench:inspection-interference --enable-benchmarks
nix develop -c cabal list-bin bench:inspection-interference
cd ../keiro
```

If the implementation baseline has advanced, record and use that exact commit instead.
If the worktree already exists, verify its commit and reuse it; never reset it automatically.
Each checkout's default `dist-newstyle` directory is separate. Copy no candidate production
code into the baseline. Save the returned path for the matched-run script.

Cabal runs the HTTP benchmark in `keiro-ops-http`, so the example output directories are
relative to that package. Collect them into `keiro/bench/results/pm-types/` with source/mode
labels and without overwriting any prior trial. Fifty operations per second is an initial
probe, not an assumed safe rate; fix the final offered rate using the measured capacity and
record it before comparison. Benchmark success prints artifact paths; the six guard run must
end with `BENCH_REGRESSION=PASSED` and six successful `GUARD(...)` statuses.

After milestones 2 and 3, run:

```bash
nix develop -c cabal test keiro-test keiro-ops-test keiro-ops-http-test jitsurei-test --test-show-details=direct
nix develop -c cabal run jitsurei:exe:jitsurei-demo -- ops pm types --json --database-url "$DATABASE_URL"
```

The manual command needs a disposable migrated database configured for Jitsurei; the test
suite owns its fixtures and is the reproducible acceptance route when no such URL is supplied.
The CLI output on that host must equal the JSON example below. For an already-running host
mounting that catalog, `curl -fsS http://127.0.0.1:9092/pm/types` must return the same object.
The standalone database-only executable deliberately has no application catalog.

After adding the milestone 4 harness, these are individual diagnostic invocations; run the
script's alternating pairs for final acceptance, not two large sequential cohorts:

```bash
nix develop -c cabal bench inspection-interference --benchmark-options='--output bench/results/pm-types/candidate-active --rate 50 --trials 1 --mode pm-types +RTS -N2 -T -RTS'
nix develop -c cabal bench inspection-interference --benchmark-options='--output bench/results/pm-types/candidate-many --rate 50 --trials 1 --mode pm-types-many +RTS -N2 -T -RTS'
nix develop -c env KEIRO_INSPECTION_RETENTION_SECONDS=60 cabal bench inspection-interference --benchmark-options='--output bench/results/pm-types/candidate-retention --rate 50 --trials 1 --mode pm-types +RTS -N2 -T -RTS'
nix develop -c cabal list-bin bench:inspection-interference
```

Repeat retention for `pm-types-many`. Run `cabal list-bin` in each checkout after building,
then pass those two returned executable paths and the fixed measured rate to the new script:

```bash
nix develop -c bash scripts/measure-pm-types.sh "$PM_TYPES_BASELINE_BINARY" "$PM_TYPES_CANDIDATE_BINARY" "$PM_TYPES_OUTPUT_DIRECTORY" "$PM_TYPES_OFFERED_RATE"
nix develop -c z3 --version
nix develop -c just release-gate
nix develop -c git diff --check
```

Set the four `PM_TYPES_*` variables to the two recorded executable paths, a fresh evidence
output directory, and the chosen numerical rate. The script must document its effective
settings and return nonzero on regression or inconclusive evidence. The final release-gate
command runs correctness then every historical guard serially; no release is performed.
Retain its combined log and ensure it corresponds to the final implementation tree.


## Validation and Acceptance


For Jitsurei, both JSON surfaces return exactly:

```json
{"items":[{"name":"jitsurei-fulfillment","category":"fulfillment","snapshots_configured":false,"snapshot_policy":"never","timers_configured":null}]}
```

The library summary list is sorted by catalog lookup name and includes uninstantiated
managers and aliases. JSON null means timer configuration is unknown. A configured codec
with policy `never` still reports `snapshots_configured: true`, consistent with aggregate
types; no field claims a persisted snapshot or timer exists. Empty mounted catalogs succeed,
unmounted catalogs fail parsing, and existing named reads keep their behavior.

The direct handler must perform zero store operations; its pure summary must never invoke
application callbacks or hydrate state. HTTP performs the existing schema verification and
no additional database reads for discovery. No changes to runtime append, hydration, reaction,
timer scheduling, worker loops, schemas, dependency pins, or indexes are expected. Inspect the
production diff and explain any deviation before considering it accepted.

Performance acceptance has no allowed slowdown budget. For each comparison retain at least
five alternating pairs, all raw writer timings, throughput, p95 and p99 latency (the latency
below which 95% or 99% of completed operations fall), writer-thread bytes per operation,
request successes/errors, and source/environment identity. Report paired median ratios and
95% confidence intervals using trials as independent samples, with a fixed-seed resampling
analysis documented in the script. Retain same-source control pairs and their spread. Do not
treat thousands of correlated operations within one trial as thousands of independent trials.

A statistically supported degradation in writer throughput, capacity, p95/p99 latency, or
writer-thread allocation blocks completion, however small. Any extra deterministic ordinary-path
query, callback, metadata encoding, or task also blocks completion. If a degradation is suggested
but unresolved, extend the paired runs and investigate; do not call it a pass. Intervals too wide
to exclude a 1% degradation are insufficient measurement resolution and require more evidence;
1% is a maximum uncertainty bound, not an allowed regression. Acceptance means no detected
regression at the recorded resolution, no adverse reproducible trend, and exact structural
zero-work invariants, not a claim that finite measurements prove absolute equality. Neither the
older 5% inspection guard nor the 25% CSV guard can override a smaller reproducible regression.

Compare aggregate process allocation only as a diagnostic: new inspection requests necessarily
allocate their response, and dividing all process bytes by writer completions would misattribute
inspection allocation to the writer. Fail tests on missing load or rejected polls in the declared
normal workload; use deliberate overload only to verify bounded refusal and recovery. Repeated
catalog requests must release admission permits, retain no growing per-request state, and leave
no active client tasks after cleanup. The large-catalog case must stay under the ordinary response
cap; a deliberately oversized response must fail explicitly rather than truncate.

Milestone 4 is incomplete if baseline quality, measurement noise, or the final repository gate
remains unresolved. Do not loosen thresholds, rewrite baseline CSVs, suppress schema checks,
remove load, or enable result caching to manufacture passing evidence.


## Idempotence and Recovery


Tests and benchmarks use disposable fixtures and can be repeated. Use fresh output directories;
keep failing evidence alongside successful reruns with an explanation. Detached baseline
worktrees and their build outputs are measurement artifacts; do not delete or reset unrelated
work. Retry a failed build before starting any timing runs. A source change after measurement
invalidates affected evidence and requires the corresponding final-candidate rerun.

Implementation is additive and needs no data migration. If the design fails performance
acceptance, retain the red evidence and simplify or correct the implementation; do not mark the
feature complete. Every implementation commit uses Conventional Commits and includes
`ExecPlan: docs/plans/323-list-mounted-process-managers-without-runtime-performance-regressions.md`
and `Intention: intention_01m5wt12qte7wrtk3r031syktj` trailers. Record the implementing model's
provenance revision with the bundled script on the first substantive plan update.


## Interfaces and Dependencies


Add this public interface in `keiro/src/Keiro/ProcessManager/Inspect.hs`:

```haskell
data ProcessManagerTypeSummary = ProcessManagerTypeSummary
  { name :: !Text,
    category :: !Text,
    snapshotsConfigured :: !Bool,
    snapshotPolicy :: !Text,
    timersConfigured :: !(Maybe Bool)
  }
  deriving stock (Eq, Show, Generic)

listProcessManagerTypes :: ProcessManagerInspectors -> [ProcessManagerTypeSummary]
processManagerTypeJson :: ProcessManagerTypeSummary -> Value
```

All current constructors produce summaries with `timersConfigured = Nothing`; this type
leaves an honest representation for future known values without inventing timer detection now.
Existing `ProcessManagerInspector`, `ProcessManagerInspectors`, and `AppHooks` remain unchanged.
The ops command adds `Types`, whose JSON is `object ["items" .= map processManagerTypeJson summaries]`.
HTTP continues to use the parser and owning runner; there is no independent route definition.

The summary additionally implements `ToJSON` with value/encoding parity. Ops exports
`prepareTypes :: ProcessManagerInspectors -> (OpsResult, Encoding)` and
`runCommandWithReadEncoding :: (Encoding -> IO (Maybe ByteString)) -> WorkflowHeaderCache -> AppHooks -> OpsEnv -> Command -> IO (OpsOutcome, Maybe ByteString)`.
The HTTP budget exports `encodeBoundedEncoding :: Int -> Encoding -> IO (Maybe LazyByteString)`.
These are additive adapters over existing Aeson/bytestring dependencies; every host
encoder is required to apply its own response-byte/deadline budget.

No external dependency upgrade or new production dependency is required. The CLI parser uses
the existing `command`/`info`/`pure` pattern already present for aggregate types. Mori discovery
located and source-checked the parser package at
`mori://pcapriotti/optparse-applicative/packages/optparse-applicative`; no version choice is made
by this plan. If implementation discovers a need to change an external API or version, first
use Mori to inspect source/documentation and verify the current release against its registry
and upstream tags. Jitsurei is a repository-local test/benchmark dependency only.
