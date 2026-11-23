# Adopt the Keiro runtime and DSL in this project

Selected mode is `{{adoption.mode}}`. Work in the target checkout from which
Seihou was invoked, following its instructions and preserving unrelated edits.
Stop on an unsupported mode. One run covers one target repository. Review each
in-scope shipped service or workspace in that repository. Use an explicit
operator scope when supplied and record anything outside it.

- `prepare` verifies the released cohort, performs an applicable dependency
  upgrade, creates or updates the adoption MasterPlan and child ExecPlans, and
  completes the domain audit's Stage 1. End after the reviewed baseline and
  plan handoff.
- `implement` verifies or resumes preparation, then executes the accepted work
  in dependency order and closes the domain audit on the final candidate.
  Respect any narrower execution boundary given by the operator.

On reruns, recover the existing plan, version window, evidence, and baseline
before writing new artifacts. Do not start a second adoption plan for work
already covered. Use the repository's MasterPlan and ExecPlan authoring tools
when available. Follow its normal source, Intention, and commit conventions.

## 1. Establish the version and history

1. Identify the deployed packages, executables, workers, migration targets,
   supported build configurations, development shell, CI, and existing
   workspaces/generator. Review the last deployed release and retained data,
   queues, checkpoints, and public contracts. If usage is unknown, plan for
   retained history and existing consumers. A fresh private cutover requires
   evidence that there is no retained data or an explicit owner decision.
2. Use Mori to locate the authoritative Keiro and substrate source, registry,
   and documentation. Verify each selected release against the authoritative
   package registry and upstream release tags. Read the release documentation
   at that version. Use canonical Mori artifact references in durable outputs.
   If an artifact URI is not yet resolvable, find the owning project and read
   its project-relative source while retaining the canonical artifact URI.
3. Resolve the actual in-scope components in their normal build environment.
   For Cabal, run the project's normal build targets with `--dry-run` and its
   project file, flags, and test configuration, then inspect the resulting
   `install-plan` package IDs and component closures. Use the equivalent
   resolved package inputs for Nix or another supported build. Check that
   every used Keiro runtime package resolves to a compatible released
   **0.26.0.0 or newer** cohort. A lower bound, a checkout version, an old
   plan.json, or an unrelated component on 0.26+ cannot pass the check. Use
   numeric version comparison. Record the release, package resolution,
   relevant build inputs, and the evidence for each component. Verify the
   actual scaffold command uses a compatible released `keiro-dsl` that matches
   the target cohort, including a generator built or pinned separately.
4. Keep an already qualified cohort. If production is on an older release or
   the dependency pin moved without the application migration, establish the
   true old version from a pre-upgrade solve or deployment inputs. Select a
   compatible released 0.26+ target and record both ends before changing
   pins. Review solver changes for Keiro and the resolved substrate it uses.
   Record the index snapshot or lock inputs and keep unrelated pins unless a
   demonstrated conflict requires a change. Projects with no older Keiro
   consumer have no historical Keiro upgrade edges; prove the chosen initial
   cohort in their real build instead.

## 2. Cross the upgrade window when needed

Use [keiro-upgrade](mori://shinzui/keiro/blueprints/keiro-upgrade) and its declared
entailed blueprints. Read the installed descriptor, edge prompts and cohort
reference. Install or refresh the relevant registered artifacts from their
owning registries and verify the blueprint identities and versions. Check the
same-origin provenance when resuming an existing run. The actual declared
window determines the required substrate blueprints. The prerequisite commonly
includes [Kiroku](mori://shinzui/kiroku/blueprints/kiroku-upgrade),
[the PGMQ adapter](mori://shinzui/shibuya-pgmq-adapter/blueprints/shibuya-pgmq-adapter-upgrade),
and [the Kiroku adapter](mori://shinzui/kiroku/blueprints/shibuya-kiroku-adapter-upgrade).
A gap with no prescribed source migration is valid. Resolve any missing
required edge or prerequisite before applying the window. If the operator
identified a local Keiro checkout, use its verified absolute directory for
the root upgrade blueprint. Entailed artifacts still resolve by their
installed names.

Use the recorded before/after versions explicitly. Set the target dependency
pins for the selected solve first, as the upgrade blueprint directs. Preview
and inspect the actual expansion and order before the real run.

```sh
seihou agent --debug migrate keiro-upgrade --from "$from_version" --to "$to_version"
seihou agent migrate keiro-upgrade --from "$from_version" --to "$to_version" --batch
```

Use an authenticated tool-capable provider and review permissions for nested
runs. The real run is the prerequisite. A required edge outside the published
migration coverage needs its own reviewed migration plan before adoption
can proceed. Record applied and inapplicable
dispositions with their owning edge and evidence. Rerun the same window to
resume from receipts. Inspect partial edits before retrying a failed run.
A dry run or a receipt alone cannot prove migration. Do not manufacture
receipts or use version/origin overrides to hide a mismatch. If access is
blocked, record the failed edge and command. Use the migration guidance to
review and finish partial edits within scope, then run the actual tool and
verify the result.

Confirm the new solve, build the actual roles, and exercise the application's
affected runtime and migration tests in its development environment. Select
at least one real boundary that changed and demonstrate its behavior. Record
the source checkpoint and remaining limitations. Do not begin adoption
source changes with a failed or unverified cohort gate. Keep the qualified
upgrade and its test evidence as a separate checkpoint from the adoption
refactors.

## 3. Create or reconcile the implementation plans

Read the applicable rules from
[domain design](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-design),
[DSL adoption](mori://shinzui/keiro-runtime-patterns/docs/keiro-dsl-adoption),
[brownfield adoption](mori://shinzui/keiro-runtime-patterns/docs/keiro-brownfield-adoption),
[language versions](mori://shinzui/keiro-runtime-patterns/docs/keiro-language-versions),
[runtime assembly](mori://shinzui/keiro-runtime-patterns/docs/keiro-runtime-assembly),
[behavior conformance](mori://shinzui/keiro-runtime-patterns/docs/keiro-behavior-conformance),
[evolution and rollout](mori://shinzui/keiro-runtime-patterns/docs/keiro-evolution-and-rollout),
and [domain newtypes and TypeIDs](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
Use Mori to find the narrower guides for each applicable surface and record
the specific rule used in the owning child plan.
Use the completed [Kawa MasterPlan](mori://shinzui/kawa/masterplans/6-adopt-the-keiro-runtime-and-dsl-across-kawa)
as a worked example. Its fresh-store policy, counts, tool paths, and service
topology are specific to that project.

For each relevant capability, map the real entry point, current owner,
durable and external contracts, declaration or runtime API, retained app
adapter, proof, and owning plan. Include aggregates, commands and validated
streams, deterministic and externally owned IDs, mapped types and codecs,
behavior witnesses, inbox/outbox and trace, dispatch and queues, queries and
projections, processes and timers, workflows, snapshots and upcasters, and
operational ownership. Document capabilities with no applicable use and
grammar-only surfaces with their actual adapters. Distinguish release
availability from what the chosen generator emits and what production calls.

Create a target-local MasterPlan with prerequisite evidence, dependency graph,
scope, integration points, risks and gates. Write child ExecPlans with actual
paths, callers, fixture commands, compatibility decisions, and acceptance
checks. Prefer independently verifiable slices:

1. Source-bound domain audit baseline and assignment of findings.
2. Checked workspace, shared types and real command/replay paths.
3. Applicable runtime consumers, grouped by actual shared interfaces. This
   can include messaging, processes or workflow boundaries, projections and
   reads, or operations. Keep independent slices independent.
4. Residual audit remediation and integrated fresh-source qualification.

Choose a single DSL file or a service workspace based on the real domain and
release. If a trivial single-aggregate service meets the adoption guide's
exception, document why and which runtime rules still apply. For DSL adoption, specify Language 6 explicitly in every in-scope
member and check the effective version. Preserve the sole owner of each
name, schema, state machine, transaction, identity recipe, and retained codec.
Use supported generated bindings rather than a parallel domain model. Carry
unauthorized leakage, replay and checkpoint hazards into plan acceptance.
For an existing deployment, record the comparison base, historical codec
fixtures, retained replay and current write-path parity, upgrade order,
rollback or forward recovery, and any operator-owned handoff.

## 4. Run the domain audit at the planned boundaries

Resolve [domain-scalar-identity-decoder-audit](mori://shinzui/keiro/blueprints/domain-scalar-identity-decoder-audit)
at a version with the `audit.stage` setting. Verify its source and rendered
scope. Use its absolute directory when the operator identifies a matching
local checkout. Use `--no-baseline` for these invocations and give the audit
agent the existing baseline child's path and evidence location.

```sh
seihou agent run domain-scalar-identity-decoder-audit \
  "Complete and record the baseline for the existing adoption plans." \
  --no-baseline --var audit.stage=classification
```

For both modes, require complete classified coverage before the first
adoption refactor. Freeze accepted baseline evidence under its source/build
identity. Review the provider's census and classifications against real
production and generated sources, correct unsupported judgments, trace
authorities, and send findings to the relevant child plans. Baseline
violations are expected inputs to remediation. Pending, missing, and stale
coverage cannot pass. A provider grace exit, preview, or manifest receipt
does not establish this gate. If the provider cannot perform the job,
inspect partial edits, use permitted tool grants or an authenticated
interactive provider, and verify independently. Report missing verification
as pending.

In `prepare`, return the verified cohort, MasterPlan, child plans, reviewed
baseline and exact next milestone. Do not begin adoption refactors. In
`implement`, execute the plans in order and use actual callers and migration
owners. Carry each baseline finding to a fixed owner or a substantive
replacement with a regression control. Resume the existing audit for final
acceptance:

```sh
seihou agent run domain-scalar-identity-decoder-audit \
  "Resume the recorded baseline and adoption handoffs. Resolve residual findings and accept the final integrated source." \
  --no-baseline --var audit.stage=all
```

## 5. Qualify and close the project

Require a current source-bound census and complete final classifications
including generated modules and hand-owned bindings. Trace baseline findings
and require zero pending or unresolved violations. Capture the source revision,
dirty-diff identity when applicable, guide and tool versions, build inputs,
commands, counts and evidence paths.

Build the shipped roles through the actual package graph. From a clean
checkout regenerate twice, compare all generated artifacts and topology, and
run `keiro-dsl diff` against the appropriate deployed or first checked
baseline. Run the generated `--behavior-complete` suite where applicable,
record unverified proof status distinctly, and show that a removed witness
and a deliberate breaking compatibility change fail their intended gates.
Check binding laws, historical replay and the separate current write path
when the service retains history. Prove selected use cases through actual
runtime entry points, including refusal/rollback, idempotence, restart,
authorization and the correct external delivery or rebuild where those
boundaries exist. Enable applicable integration-test gates against
disposable fixtures and report any skipped check. Verify public schemas and
generated clients or record a reviewed contract change.

Mark child plans and the MasterPlan complete only after their stated gates
pass. Report evidence paths, exact verified revisions, and any unresolved
owner or environment blocker.
