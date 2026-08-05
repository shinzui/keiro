---
id: 193
slug: surface-the-effective-language-contract-and-enforce-warnings-in-ci
title: "Surface the effective language contract and enforce warnings in CI"
kind: exec-plan
created_at: 2026-08-05T04:54:27Z
intention: "intention_01kz84b5jre3187dmmyjmd02fc"
master_plan: "docs/masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md"
---

# Surface the effective language contract and enforce warnings in CI

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this work, a CI pipeline can prove that a `.keiro` specification validates under the
documented language contract with zero tolerated warnings — and it can prove it from exit codes
and a stable JSON report instead of scraping stderr prose.

Today the opposite is true, silently. A `.keiro` file that omits the `language keiro-dsl 4`
preamble is treated as a legacy version-1 source, and only language 4 enforces the whole
plan-180 family of spec-surface closure checks (duplicate declarations, duplicate registers and
columns, topic-alias resolution, discriminator shadowing, schema-version floors, and more). An
adopter who reads the reference — which documents language 4 only — believes those checks ran.
`keiro-dsl check` prints `OK` and exits zero without ever saying which contract it actually
applied. Separately, `check` exits non-zero only on error-severity diagnostics: warnings —
including two whose message text describes a guaranteed runtime failure — cannot gate a merge,
there is no escalation flag, and there is no machine-readable output for `check` at all.

After this plan, four things are visibly different:

1. `keiro-dsl check` (and `scaffold`, and the working-tree side of `diff`) prints one stderr
   notice line naming the effective language contract whenever it is not the stable registry
   row, stating plainly that language-4 strict validation is not applied.
2. `keiro-dsl check --min-language 4 spec.keiro` exits 1 with a located, stable-coded error
   (`LanguageVersionBelowMinimum`) when the effective version is below the floor, so CI can
   refuse under-versioned specs.
3. `keiro-dsl check --deny-warnings spec.keiro` (and the selective
   `--deny CODE[,CODE...]` form) exits 1 when any (or any named) warning fires, without
   changing any diagnostic's severity.
4. `keiro-dsl check --report-out report.json spec.keiro` writes schema
   `keiro-dsl/check-report/1`: the effective language, every diagnostic with code, severity,
   file, line, and message, and summary counts — following the append-only conventions of the
   existing `keiro-dsl/diff-report/1`. Codes added later by ExecPlans 194 and 197 flow through
   this schema without change.

To see it working: run `cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/language-legacy.keiro`
from the repository root inside `nix develop`. Before this plan it prints `OK` and nothing else.
After milestone 1 it additionally prints the effective-contract notice on stderr, and with
`--min-language 4` it exits 1 with a coded error at line 1 of the fixture.


## Progress

- [x] (2026-08-04) Verify the audit evidence against `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`,
  `keiro-dsl/src/Keiro/Dsl/Validate.hs`, `keiro-dsl/app/Main.hs`, `keiro-dsl/test/Main.hs`, and
  `docs/user/typed-spec-toolchain.md`; enumerate all nine warning-severity diagnostic sites; author
  this plan under Intention `intention_01kz84b5jre3187dmmyjmd02fc`.
- [x] (2026-08-05 07:53 PDT) Milestone 1: emit the effective-language notice from
  check/scaffold/diff (single-file and workspace paths), add `--min-language` with the appended
  `LanguageVersionBelowMinimum` code, and update the existing CLI tests that asserted empty check
  stderr for non-stable fixtures. The exact assertions changed were the declared-v1 check and the
  two contextual-identifier check cases; the scaffold assertions were already contains-based.
  The `language support` focused group passes 4 examples and the `source language version` group
  passes 21 examples, including source/workspace floors and a working-tree-only diff notice; the
  full `keiro-dsl-test` suite passes 569 examples with zero failures.
- [ ] Milestone 2: add `--deny-warnings` and `--deny CODE[,CODE...]` with the documented exit-code
  contract, `Enum`/`Bounded` derivation plus `parseDiagnosticCode` for the code spelling, and CLI
  tests proving escalation and non-escalation.
- [ ] Milestone 3: add `Keiro.Dsl.CheckReport` writing schema `keiro-dsl/check-report/1` from both
  check paths via `--report-out`, with round-trip/shape tests and a golden fixture.
- [ ] Milestone 4: ratify the warning-policy review in the Decision Log, update
  `docs/user/typed-spec-toolchain.md` (check reference, validation model, CI recipe), amend
  ADR 0004 and `docs/adr/log.md`, update `CHANGELOG.md` and `keiro-dsl/CHANGELOG.md`, and run the
  full closure commands.


## Surprises & Discoveries

- Observation: the existing CLI test suite asserts empty stderr for `check` on a declared
  version-1 fixture, so milestone 1's notice is a deliberate behavioral change to a tested
  contract, not a purely additive line.
  Evidence: `keiro-dsl/test/Main.hs:611-615` (`v1Err \`shouldBe\` ""` after
  `runKeiroDsl ["check", "test/fixtures/language-v1.keiro"]`) and `test/Main.hs:629-635` for the
  contextual-identifier fixtures.

- Observation: `diff` never calls `validateService`; it parses both revisions and classifies
  changes. Its effective-contract notice therefore attaches at contract selection (after
  `checkedSource`/`checkedWorkspace`), not at a validation gate, and only the working-tree side
  is noticed because the historical side is legitimately allowed to be an older contract.
  Evidence: `run (Diff ...)` in `keiro-dsl/app/Main.hs:314-349` builds `checkedSource` for both
  sides and goes straight to `diffSources`.

- Observation: exactly nine `DiagnosticCode` values are ever emitted at `Warning` severity, all
  in `keiro-dsl/src/Keiro/Dsl/Validate.hs`: `WqUnloggedDurability` (~line 1896),
  `ProcessBenignInversion` (2301, 2305, 2421), `PolicyDeadLetterUnused` (2449),
  `AmbiguousFollowsRejectedPolicy` (2456), `RmProjectionWithoutNode` (2744),
  `EventRetirementInProgress` (2862, 2884), `DeprecatedEventReplayHazard` (2873),
  `WireSchemaVersionMismatch` (2900), and `ReplayOnlyCommandStillLive` (2924). This is the
  complete inventory the warning-policy review in milestone 4 must cover.


## Decision Log

- Decision: The effective-contract notice is one line on stderr, printed whenever the effective
  contract's registry support is not `Stable` (which covers both legacy-unversioned sources and
  declared compatibility-only versions 1–3). It is emitted by `check` and `scaffold` on both the
  single-file and workspace paths, and by `diff` for the working-tree side only.
  Rationale: stdout is a machine surface (`OK`, `--emit` canonical bytes, coverage summaries) and
  must stay byte-stable; stderr is where every diagnostic already lives. `scaffold` shares
  `check`'s validation gate, so a scaffold user deserves the same honesty. `diff`'s historical
  side may legitimately be an older released contract, so noticing it would be noise; the
  working-tree side is what will be scaffolded next. `behavior-obligations` and `inspect` are
  deliberately unchanged — `inspect --format json` already reports provenance exactly, and
  keeping the noticed command set minimal keeps the contract reviewable.
  Date: 2026-08-04

- Decision: The language floor is a flag, `--min-language N`, on `check` only, with no
  environment-variable form. `N` must be a registered released version (currently 1–4);
  anything else is refused by the option reader itself.
  Rationale: an env-var override would make a CI invocation non-reproducible from its command
  line, and the toolchain has no existing env-var surface — introducing one for a gate would be
  a new configuration channel with no precedent. Refusing an unregistered floor at parse time
  turns a CI misconfiguration (a floor no spec can ever meet) into an immediate, obvious
  failure instead of a permanently red pipeline that looks like a spec problem.
  Date: 2026-08-04

- Decision: A floor violation is a new appended `DiagnosticCode`, `LanguageVersionBelowMinimum`,
  emitted at `Error` severity and located at the language preamble line (line 1 for a
  legacy-unversioned source; the manifest plus per-member notes for a workspace). It renders
  through the existing `renderDiagnostic` / `renderWorkspaceDiagnostic` pipeline and appears in
  the JSON report like any other diagnostic.
  Rationale: ADR 0004 requires tooling to branch on stable codes, and its `DiagnosticCode`
  inventory is append-only; the spelling follows the existing `…BelowMinimum` family
  (`PublisherMaxAttemptsBelowMinimum`, `ContractSchemaVersionBelowMinimum`). Emitting through
  the existing pipeline means EP-194/EP-197 diagnostics and this one share one rendering and one
  report path — this plan owns that contract for the MasterPlan.
  Date: 2026-08-04

- Decision: The code spelling users pass to `--deny` is exactly the constructor rendering that
  already appears inside `warning[Code]` on stderr — for example
  `--deny DeprecatedEventReplayHazard`. `DiagnosticCode` gains derived `Enum` and `Bounded`
  instances, and a total `parseDiagnosticCode :: Text -> Maybe DiagnosticCode` is built from
  them; an unknown code is refused by the option reader.
  Rationale: users discover codes by reading `check` output, so the deny spelling must be
  copy-pasteable from it. `show` is already the machine-visible rendering (tests and the diff
  report rely on it), so no second spelling registry is introduced. All constructors are
  nullary, so `Enum`/`Bounded` are derivable and the parse map can never drift from the enum.
  Date: 2026-08-04

- Decision: `--deny-warnings` and `--deny` escalate the exit code only; they never change a
  diagnostic's rendered severity, its severity in the JSON report, or the validation pipeline.
  The effective deny set is the union of both flags (`--deny-warnings` denies every code;
  `--deny` is repeatable and comma-splittable). Denying a code that only ever fires as an error
  or that does not fire at all is a harmless no-op, so CI deny lists stay stable across specs.
  After diagnostics print, a denied non-empty warning set adds one stderr summary line and
  exits 1. Errors fail regardless of deny flags, and the exit code remains uniformly 1 for
  every failure class (parse failure, errors, floor violation, denied warnings, coverage
  failure) — the report, not the exit code, says why.
  Rationale: ADR 0004's consequence — "`check` may warn rather than reject when the missing
  fact is operational history" — is about severity classification, and this design leaves
  classification untouched: escalation is a per-invocation CI policy, not a reclassification.
  Multi-valued exit codes would be a new compatibility surface with no consumer; every existing
  gate in this toolchain treats non-zero as fail and reads structured output for the reason.
  Date: 2026-08-04

- Decision: The check report is schema `keiro-dsl/check-report/1`, written by `--report-out FILE`
  on `check` (single-file and workspace), mirroring `keiro-dsl/diff-report/1` conventions: a
  top-level `schema` string, append-only object keys, readers must ignore unknown keys, and
  `Aeson.encodeFile` semantics. It is written whenever validation ran — including when errors
  are present, before exit gating, exactly as `diff --report-out` writes its report before the
  breaking gate — and is not written on a parse or compose failure, because no checked graph
  exists to report on (mirroring `diff`, which requires both parses). Diagnostic codes appear as
  plain strings, so codes added by EP-194/EP-197 require no schema change.
  Rationale: one report convention across the toolchain (established by ADR 0004's diff-report
  contract) is cheaper for consumers than two; writing the report even on failure is what makes
  it useful to CI, which mostly reads it when something went wrong.
  Date: 2026-08-04

- Decision: Record the report schema and the new enforcement surface by amending ADR 0004
  rather than writing a new ADR, in milestone 4, and update `docs/adr/log.md` accordingly. No
  other ADR needs changing.
  Rationale: ADR 0004 is already the durable home of exactly this material — it names the
  `keiro-dsl/diff-report/1` schema and its append-only/ignore-unknown rules in its Decision
  text, owns the append-only `DiagnosticCode` registry that `LanguageVersionBelowMinimum` joins,
  and its Consequences section says the inventory is amended when a gate's surface changes. A
  separate ADR would split the machine-contract inventory across two documents. The amendment
  must also state explicitly that warning escalation is a per-invocation CI policy and that the
  "check may warn when the missing fact is operational history" consequence is unchanged.
  Because `docs/adr` is a profile-governed OKF bundle, closure runs its strict validation.
  Date: 2026-08-04

- Decision (warning-policy review, operational-history class): `DeprecatedEventReplayHazard`,
  `EventRetirementInProgress`, and `ReplayOnlyCommandStillLive` stay warnings permanently under
  the current inventory. Each becomes enforceable in CI via `--deny`, and
  `DeprecatedEventReplayHazard` is the flagship example in the CI recipe.
  Rationale: for all three, the missing fact is operational history, which is exactly ADR
  0004's stated reason `check` may warn: whether any live stream still contains the deprecated
  event (`DeprecatedEventReplayHazard` — its message correctly says hydration of such a stream
  fails with `HydrationNoInvertingEdge`, but a fleet whose streams are all terminalized or
  truncated is legitimately clean), whether affected streams have drained during retirement
  (`EventRetirementInProgress`), and whether full command retirement rather than event
  retirement is the operator's intent (`ReplayOnlyCommandStillLive`). A spec cannot decide any
  of these; the database-backed replay audit is their sound boundary. Making them deniable
  gives CI the "guaranteed failure unless you have proven your history clean" posture without
  falsifying the severity model.
  Date: 2026-08-04

- Decision (warning-policy review, deliberate-policy class): `WqUnloggedDurability`,
  `ProcessBenignInversion`, `AmbiguousFollowsRejectedPolicy`, and `PolicyDeadLetterUnused` stay
  warnings with no future reclassification proposed here.
  Rationale: the first three describe explicitly chosen, internally coherent policies (an
  unlogged queue is legitimately transient; benign inversion and rejected-policy fallthrough
  are the documented semantics of deterministic dedupe); refusing them would remove sanctioned
  configurations. `PolicyDeadLetterUnused` is an inert-surface finding, and inert-surface
  triage is EP-197's owned scope (`docs/plans/197-enforce-or-refuse-every-accepted-spec-surface.md`
  once created; see the MasterPlan registry) — this plan makes it deniable and leaves its
  classification to EP-197 to avoid two plans ruling on one surface.
  Date: 2026-08-04

- Decision (warning-policy review, internally-decidable candidates): `WireSchemaVersionMismatch`
  and `RmProjectionWithoutNode` stay warnings in this plan but are recorded as candidates for
  error under a future language version's strict profile. They are not reclassified now.
  Rationale: both facts are fully internally decidable from one spec (a declared
  `wire schemaVersion=` that differs from the maximum event version; a projection with no
  `readmodel` node), so ADR 0004's operational-history rationale does not protect them — but
  reclassifying inside released language 4 would hard-refuse existing valid specs, which is the
  retroactive-tightening failure mode the MasterPlan explicitly forbids (the Mori `family`
  lesson). The default posture of this plan is: keep severities, make them enforceable. A
  future language version (or EP-197 under its language-gating rule) is the sound place to
  promote them; `--deny WireSchemaVersionMismatch,RmProjectionWithoutNode` gives any team the
  strict behavior today.
  Date: 2026-08-04

- Decision: The `Check` command's positional option tuple in `keiro-dsl/app/Main.hs` is
  replaced by a `CheckOptions` record threaded through both `run (Check …)` and
  `runWorkspaceCheck`.
  Rationale: `Check` grows from four fields to eight; positional `Bool`s at call sites are
  already at the edge of readability, and both check paths must receive identical options to
  preserve the single-file/workspace parity that the existing tests assert.
  Date: 2026-08-04


## Outcomes & Retrospective

Implementation has not started. At completion, record: the final notice wording as shipped, the
exact new test descriptions and counts, the check-report golden path, which existing stderr
assertions had to change, the ADR 0004 amendment text, and whether EP-194/EP-197 need anything
further from the report schema. Compare against the purpose: can a CI pipeline, using only exit
codes and `check-report/1`, prove "validated under language 4 with zero tolerated warnings"?


## Context and Orientation

This plan is EP-193 in Phase 1 of
[`docs/masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md`](../masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md).
Per that MasterPlan's Integration Points, EP-193 owns the `check` CLI diagnostics contract —
the effective-language notice, `--min-language`, the deny flags, and the versioned JSON report —
that EP-194 (check/scaffold refusal parity) and EP-197 (inert-surface enforcement) will emit new
diagnostics through. It has no hard dependencies and changes no generated bytes, fold
fingerprints, or wire identities.

### The language registry and the silent downgrade

A `.keiro` source may begin with a preamble line `language keiro-dsl N`. The parser records this
as a `SourceLanguage` value (`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`): either
`DeclaredLanguage` with the version and its source line, or `LegacyUnversioned` when the
preamble is absent. `effectiveLanguageVersion` (LanguageVersion.hs:310-312) maps
`LegacyUnversioned` to version 1. The append-only registry `languageRegistry`
(LanguageVersion.hs:216-262) defines four released versions; versions 1–3 carry support
`CompatibilityOnly` and only version 4 is `Stable`. Each row selects a
`RuntimeSemanticsProfile`, and only version 4's profile (`keiro-dsl/runtime-semantics/3`)
contains the capability `StrictSpecSurfaceValidation`.

`Keiro.Dsl.SemanticContract` resolves a `SourceLanguage` to an `EffectiveLanguageContract`
(version + runtime profile) and pairs it with the normalized graph as `CheckedService`.
Validation consults the capability through `enforcesSpecSurfaceClosures`
(`keiro-dsl/src/Keiro/Dsl/Validate.hs:435-437`); roughly thirty rule sites guard on it. An
unversioned spec therefore silently loses the entire plan-180 closure family: duplicate
id/enum/nominal/rule declarations (the diagnostic text itself says "the last declaration would
silently replace the earlier one"), duplicate registers, duplicate read-model columns, Kafka
topic charset checks, unresolved contract topic aliases, discriminator shadowing, intake
bind/dedupe field resolution, schemaVersion floors, envelope-policy vocabulary,
unguarded-sibling transitions, stable-identity validity, `wire` clause support, publisher
floors, and Postgres identifier validity. `check` then prints `OK` with no indication
(`keiro-dsl/app/Main.hs:229-253`); the only place the effective contract is visible today is
`inspect --format json` (Main.hs:293-299 and `sourceInspection`, Main.hs:362-372).
Meanwhile `docs/user/typed-spec-toolchain.md:9-14` states the reference "describes Language 4
only", so adopters believe they get the documented validation and silently do not.

### The current check/exit contract

In `keiro-dsl/app/Main.hs`, `run (Check …)` (lines 229-253) parses, builds `checkedSource`,
runs `validateService`, renders each `Diagnostic` to stderr via `renderDiagnostic`
(`<file>:<line>: error[Code]: message` — Validate.hs:391-409), and calls `exitFailure` only when
`any ((== Error) . severity)` holds (lines 240-241). The workspace twin `runWorkspaceCheck`
(Main.hs:451-476) does the same with `checkWorkspace` and `WorkspaceDiagnostic` (a
multi-location diagnostic defined in `keiro-dsl/src/Keiro/Dsl/Workspace.hs:538-593`; its first
`WorkspaceLocation` renders as the primary `file:line`, the rest as indented notes).
`scaffold` (Main.hs:254-288, error gate at 267) and `behavior-obligations` (gate at 309) apply
the same error-only gate. Warnings are printed and forgotten:
`docs/user/typed-spec-toolchain.md:1543-1558` (the "Validation model" section) codifies
"Warnings are printed but do not make `check` fail." There is no escalation flag and no
machine-readable output for `check` — JSON exists only for `inspect`, coverage reports, diff
reports, and replay impact. CI that wants to gate on a warning must scrape stderr.

The nine warning-only codes and their sites are enumerated in Surprises & Discoveries above.
Two of them describe guaranteed failures when their operational precondition is false:
`DeprecatedEventReplayHazard` (Validate.hs:2870-2881) says hydration of a live stream containing
the event "fails with HydrationNoInvertingEdge", and `WireSchemaVersionMismatch`
(Validate.hs:2894-2907) reports a declared wire schema version that disagrees with the maximum
event version.

### The report precedent to follow

`diff --report-out FILE` writes schema `keiro-dsl/diff-report/1` via `Aeson.encodeFile`
(Main.hs:347 for single files, 633 for workspaces). The schema contract lives in
`keiro-dsl/src/Keiro/Dsl/DiffReport.hs` (module header, lines 1-8): a top-level
`"schema"` key, append-only object keys, and readers that must ignore unknown keys. Workspace
input adds keys (`workspace`, `declaration`, `useSites`) without a new schema id. ADR 0004
records this contract as durable project memory. Milestone 3 replicates the pattern for check.

### CLI structure and test conventions

`keiro-dsl/app/Main.hs` uses optparse-applicative: a `Command` sum (lines 43-51), a `subparser`
tree (75-102), small `Parser` helpers per option (104-205), and a `run :: Command -> IO ()`
with workspace dispatch guards on `isWorkspacePath` (207-221). CLI tests live in
`keiro-dsl/test/Main.hs` and invoke the real executable through
`runKeiroDsl :: [String] -> IO (ExitCode, String, String)` (test/Main.hs:7663-7674), which runs
`cabal run -v0 keiro-dsl --` and resolves `test/fixtures/…` paths. Existing check tests assert
exit codes, exact stdout (`lines out \`shouldBe\` ["OK"]`), and stderr content
(test/Main.hs:611-635 for language fixtures; 5855-5903 for the workspace check CLI block).
Useful fixtures already exist: `keiro-dsl/test/fixtures/language-legacy.keiro` (no preamble),
`language-v1.keiro` (declared 1), `language-future.keiro` (unsupported), and the composed
workspace fixtures under `test/fixtures/workspace/`.

### ADR context

The local ADR scan found one directly governing decision:
[ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) —
evolution checks live at the earliest sound boundary; machine-readable `DiagnosticCode` values
are append-only and tooling branches on codes, not prose; the `keiro-dsl/diff-report/1` schema
and its append-only/ignore-unknown rules are part of its Decision text; and its Consequences
include "`check` may warn rather than reject when the missing fact is operational history, such
as whether live streams still contain a deprecated event." That consequence constrains this
plan: warnings whose missing fact is operational history must not be reclassified, only made
enforceable by explicit CI policy. Milestone 4 amends this ADR (see Decision Log). No other ADR
in `docs/adr/` governs the CLI surface, exit codes, or report schemas; ADRs 0002/0003/0014–0020
were scanned by headline and are not relevant here beyond the neutrality rule that this plan
changes no generated bytes. No cross-repository ADR applies.

Terms used below: "effective contract" means the `EffectiveLanguageContract` a source or
workspace resolves to; "stable row" means the unique registry entry whose `LanguageSupport` is
`Stable` (today: version 4); "deny set" means the set of `DiagnosticCode` values whose
warning-severity occurrences make `check` exit non-zero for one invocation.


## Plan of Work

### Milestone 1: Effective-language notice and `--min-language`

Scope: make the applied contract visible everywhere generation-relevant validation happens, and
give CI a floor. At the end, checking or scaffolding any non-stable source prints one stderr
notice line; `check --min-language N` refuses effective versions below `N` with a located,
coded error; and the existing CLI tests that asserted empty check stderr are updated to assert
the notice instead.

Add a pure function to `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs`:

```haskell
-- | One stderr line naming a non-stable effective contract, or Nothing for
-- the stable registry row. sourceFormSummary is "legacy-unversioned",
-- "declared", or a workspace-composed summary the caller provides.
languageContractNotice :: FilePath -> Text -> EffectiveLanguageContract -> Maybe Text
```

It returns `Nothing` when `effectiveLanguageSupport contract == Stable`, otherwise one line of
this exact shape (the `language contract:` prefix is the stable, greppable anchor; record any
final wording adjustment here):

```text
<subject>: language contract: effective keiro-dsl <N> (<source-form>, <support>, runtime semantics <profile-id>); language-4 strict spec-surface validation is not applied — declare `language keiro-dsl 4` to adopt the stable contract
```

In `keiro-dsl/app/Main.hs`, add an `emitLanguageContractNotice` IO helper that prints the
`Just` line to stderr, and call it: in `run (Check …)` and `run (Scaffold …)` immediately after
`checkedSource` is built (before diagnostics render, so the reader knows which contract the
following diagnostics were produced under); in `runWorkspaceCheck` and `runWorkspaceScaffold`
after `checkedWorkspace`, with a source-form summary that counts legacy-unversioned members
(for example `workspace, 2 legacy-unversioned member(s)`); and in `run (Diff …)` /
`runWorkspaceDiff` for the new (working-tree) service only. `parse`, `pretty`, `inspect`,
`behavior-obligations`, and `new` are unchanged.

Append `LanguageVersionBelowMinimum` as the last constructor of `DiagnosticCode` in
`keiro-dsl/src/Keiro/Dsl/Validate.hs` (append-only per ADR 0004), and add a pure floor check
beside `validateService`:

```haskell
-- | Error diagnostics produced when the effective version is below a
-- CI-required floor. Located at the language preamble (line 1 when
-- legacy-unversioned). Empty when the floor is met.
minimumLanguageDiagnostics :: LanguageVersion -> SourceLanguage -> [Diagnostic]
```

The message names the effective version, the source form, the floor, and the remedy
(`declare \`language keiro-dsl <floor>\``). In `Main.hs`, replace the `Check` constructor's
option tuple with a `CheckOptions` record (`emit`, `explainBindings`, coverage options,
`checkMinLanguage :: Maybe LanguageVersion`, plus fields arriving in milestones 2–3), parse
`--min-language` with an `eitherReader` that accepts only registered versions
(`lookupLanguageDefinition`; reject others with the supported list, matching the
`UnsupportedLanguageVersion` message style), and prepend the floor diagnostics to the rendered
diagnostic list on both check paths. On the workspace path, wrap the same finding as a
`WorkspaceDiagnostic` whose primary location is the manifest (line 1) and whose note locations
are each member's preamble line, so the rendered output names every file to fix. The floor
diagnostics participate in the ordinary error gate — no separate exit path.

Tests in `keiro-dsl/test/Main.hs`, using `runKeiroDsl`: legacy fixture check prints the notice
on stderr and still `OK`/exit 0; declared v4 fixture (for example
`test/fixtures/contract-v4.keiro`) prints no notice; `--min-language 4` against
`language-legacy.keiro` exits 1 with `error[LanguageVersionBelowMinimum]` at `:1:` and no `OK`;
`--min-language 1` against the same fixture exits 0; `--min-language 9` is refused by the
option parser naming supported versions; the workspace check against the composed fixture
workspace behaves identically on both paths. Update the assertions at test/Main.hs:611-635 that
expect empty stderr for compatibility-only fixtures. Also update the scaffold/diff stderr
expectations only where a test asserts exact emptiness (contains-style assertions are
unaffected); run the suite to find every site and record them in Progress.

Acceptance: the transcripts under Concrete Steps for milestone 1 match; focused matches and the
full `cabal test keiro-dsl-test` pass.

### Milestone 2: `--deny-warnings`, `--deny`, and the exit-code contract

Scope: make warnings enforceable without touching their severity. At the end, `check` can be
told to fail on all warnings or on named codes, with a stable summary line and unchanged
diagnostic rendering.

In `keiro-dsl/src/Keiro/Dsl/Validate.hs`, extend the `DiagnosticCode` deriving clause to
`deriving stock (Eq, Show, Enum, Bounded)` and add:

```haskell
diagnosticCodeText :: DiagnosticCode -> Text          -- T.pack . show
parseDiagnosticCode :: Text -> Maybe DiagnosticCode   -- total lookup over [minBound ..]
```

In `keiro-dsl/app/Main.hs`, add to `CheckOptions`: `checkDenyWarnings :: Bool` (switch
`--deny-warnings`, help "Exit non-zero when any warning-severity diagnostic fires") and
`checkDenyCodes :: [DiagnosticCode]` (repeatable option `--deny CODE[,CODE...]`, an
`eitherReader` that comma-splits and maps `parseDiagnosticCode`, refusing unknown spellings
with the exact text the user should copy from `warning[Code]`). After rendering diagnostics on
both check paths, compute the denied warnings: all warnings when `checkDenyWarnings`, otherwise
warnings whose code is in `checkDenyCodes`. When non-empty, print one stderr summary line —

```text
check: <n> warning(s) escalated to failure (denied: <Code>[, <Code>…])
```

— suppress `OK`, and exit 1. Severity words in every rendered diagnostic stay `warning`.
Errors exit 1 regardless of deny flags; deny flags never mask an error. Exit codes remain
binary (0 success / 1 any failure) as recorded in the Decision Log. `scaffold` and `diff` do
not get these flags.

Add fixture `keiro-dsl/test/fixtures/deny-unlogged.keiro`: a minimal language-4 spec containing
a workqueue with `provision unlogged`, which deterministically produces exactly one
`warning[WqUnloggedDurability]` and no errors (model it on an existing workqueue fixture).
Tests: plain check on the fixture exits 0 with the warning on stderr and `OK`; with
`--deny-warnings` it exits 1, prints the same warning line unchanged plus the summary line, and
prints no `OK`; with `--deny WqUnloggedDurability` likewise; with `--deny WireSchemaVersionMismatch`
(a code that does not fire there) it exits 0; `--deny NotACode` is refused by the parser; the
combination `--deny-warnings --deny WqUnloggedDurability` behaves as the union; and the
workspace check path honors the flags identically (drive the composed fixture workspace, which
must remain warning-free, plus a small warning-bearing workspace if none exists — record what
you add). Unit-test `parseDiagnosticCode` round-trips every constructor via
`[minBound .. maxBound]`.

Acceptance: the milestone-2 transcripts under Concrete Steps match; a spec with only warnings
is provably CI-gateable and provably not gated by default.

### Milestone 3: The `keiro-dsl/check-report/1` machine-readable report

Scope: give CI and later plans one structured artifact per check run. At the end,
`check --report-out FILE` writes a versioned JSON document from both check paths, and tests
pin its shape.

Create `keiro-dsl/src/Keiro/Dsl/CheckReport.hs` (add to `exposed-modules` in
`keiro-dsl/keiro-dsl.cabal`, beside `Keiro.Dsl.DiffReport`), following `DiffReport.hs`'s
structure: plain data types, a builder per input kind, and hand-written `ToJSON`. The module
header documents the contract verbatim: schema identifier `keiro-dsl/check-report/1`, object
keys and array element keys are append-only, and readers must ignore unknown keys. The
document shape:

```json
{
  "schema": "keiro-dsl/check-report/1",
  "kind": "source",
  "subject": "path/to/service.keiro",
  "language": {
    "sourceForm": "legacy-unversioned",
    "declaredLanguageVersion": null,
    "effectiveLanguageVersion": 1,
    "runtimeSemantics": "keiro-dsl/runtime-semantics/1",
    "languageSupport": "compatibility-only",
    "stable": false
  },
  "enforcement": {
    "minLanguage": 4,
    "denyWarnings": false,
    "denyCodes": ["DeprecatedEventReplayHazard"]
  },
  "diagnostics": [
    {
      "code": "LanguageVersionBelowMinimum",
      "severity": "error",
      "file": "path/to/service.keiro",
      "line": 1,
      "message": "…",
      "denied": false,
      "related": [{"file": "…", "line": 4, "note": "…"}]
    }
  ],
  "summary": {"errors": 1, "warnings": 0, "deniedWarnings": 0},
  "ok": false
}
```

`kind` is `"source"` or `"workspace"`; workspace reports reuse the same schema id and add an
append-only `"members"` array of `{path, sourceForm, declaredLanguageVersion}` objects (the
pattern `diff-report/1` set for workspace keys). Single-file diagnostics carry the spec path in
`file` and `relatedLocations` as `related` notes against the same file; workspace diagnostics
map their primary `WorkspaceLocation` to `file`/`line` via `workspaceDisplayPath` and secondary
locations to `related`. `severity` uses the rendered words `error`/`warning`; `denied` marks
warnings in the effective deny set; `ok` is the exact exit outcome excluding coverage (coverage
has its own report — record this boundary in the module header). Codes are open strings:
EP-194/EP-197 additions appear with no schema change.

Wire `--report-out FILE` into `CheckOptions` and both check paths: build the report after
diagnostics and denial are computed, write it with `Aeson.encodeFile` before any exit, for both
success and validation failure; a parse/compose failure exits before any report is written.

Tests: drive `check --report-out` over (1) `language-legacy.keiro` with `--min-language 4` —
decode with `Aeson.eitherDecodeFileStrict`, assert `schema`, `kind`, `stable: false`, the
`LanguageVersionBelowMinimum` entry with `severity: "error"` and `line` 1, `summary.errors`,
and `ok: false` while the process exited 1; (2) `deny-unlogged.keiro` with
`--deny-warnings` — assert the warning entry has `severity: "warning"`, `denied: true`,
`summary.deniedWarnings == 1`, `ok: false`; (3) the same without deny flags — `ok: true`,
exit 0; (4) the composed fixture workspace — `kind: "workspace"` with the members array. Add a
committed golden at `keiro-dsl/test/fixtures/check-report/legacy-min-language.golden.json` and
compare decoded `Value`s (not bytes) so key order stays free; regenerate it only through the
public CLI.

Acceptance: the milestone-3 transcript under Concrete Steps matches and all report tests pass.

### Milestone 4: Documentation, CI recipe, warning-policy ratification, and closure

Scope: make the surface documented and the policy review durable, then close.

Update `docs/user/typed-spec-toolchain.md`: in the `check` command reference (currently around
line 1440), document `--min-language`, `--deny-warnings`, `--deny`, and `--report-out` with one
example each; in the "Validation model" section (around line 1543), replace the sentence
"Warnings are printed but do not make `check` fail" with the full contract — warnings do not
fail `check` by default, `--deny-warnings`/`--deny` escalate them per invocation, and the
effective-language notice names the applied contract; state plainly that a source without the
language preamble is checked as compatibility-only language 1 without strict spec-surface
validation, and that the notice and `--min-language 4` exist precisely to surface and refuse
that. Add a short "CI recipe" subsection beside the command reference with one copy-pasteable
invocation:

```bash
cabal run -v0 keiro-dsl -- check service.keiro \
  --min-language 4 \
  --deny-warnings \
  --report-out build/keiro-check-report.json
```

and one sentence per flag on what a red result means. Include the warning-policy outcome as
prose: which codes are operational-history warnings (deniable, never auto-refused), which are
deliberate-policy warnings, and which are recorded candidates for a future language version's
strict profile, per the three Decision Log entries; ratify those entries (adjust and re-date
them if implementation taught otherwise).

Amend [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md):
add `keiro-dsl/check-report/1` beside the diff-report schema sentence with the same
append-only/ignore-unknown rules; note the appended `LanguageVersionBelowMinimum` code; and add
a Consequences sentence that warning escalation (`--deny-warnings`/`--deny`) is per-invocation
CI policy layered on unchanged severities, so the operational-history consequence stands.
Update `docs/adr/log.md` per the bundle's convention. No new ADR and no other ADR changes are
needed (see Decision Log for the rationale).

Add release notes to `CHANGELOG.md` and `keiro-dsl/CHANGELOG.md` under `[Unreleased]`: the
notice (a behavioral stderr change for compatibility-only sources), the two new flag families,
the report schema, the appended `DiagnosticCode` constructor plus new `Enum`/`Bounded`
instances (exhaustive matches unaffected; code added at the end), and the new
`Keiro.Dsl.CheckReport` module. Then run the closure commands below, update Progress, write the
Outcomes & Retrospective entry, and perform the ADR distillation pass (already planned as the
ADR 0004 amendment).


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/keiro`. Before edits, capture the
baseline behavior the plan changes:

```console
$ nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/language-legacy.keiro
OK

$ nix develop -c cabal run -v0 keiro-dsl -- inspect keiro-dsl/test/fixtures/language-legacy.keiro --format=json
{"schema":"keiro-dsl/source-inspection/1", … "sourceForm":"legacy-unversioned","declaredLanguageVersion":null,"effectiveLanguageVersion":1, …}
```

Note the absence of any contract statement from `check`. After milestone 1 (notice on stderr,
`OK` still on stdout; `2>&1` shown merged here):

```console
$ nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/language-legacy.keiro
keiro-dsl/test/fixtures/language-legacy.keiro: language contract: effective keiro-dsl 1 (legacy-unversioned, compatibility-only, runtime semantics keiro-dsl/runtime-semantics/1); language-4 strict spec-surface validation is not applied — declare `language keiro-dsl 4` to adopt the stable contract
OK

$ nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/language-legacy.keiro --min-language 4; echo "exit=$?"
keiro-dsl/test/fixtures/language-legacy.keiro: language contract: effective keiro-dsl 1 (…)
keiro-dsl/test/fixtures/language-legacy.keiro:1: error[LanguageVersionBelowMinimum]: effective language version 1 (legacy-unversioned) is below the required minimum 4; declare `language keiro-dsl 4`
exit=1
```

After milestone 2:

```console
$ nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/deny-unlogged.keiro --deny-warnings; echo "exit=$?"
keiro-dsl/test/fixtures/deny-unlogged.keiro:<line>: warning[WqUnloggedDurability]: workqueue '…': provision unlogged is truncated to empty on a database crash; use it only for transient, regenerable work
check: 1 warning(s) escalated to failure (denied: WqUnloggedDurability)
exit=1

$ nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/deny-unlogged.keiro; echo "exit=$?"
…warning[WqUnloggedDurability]…
OK
exit=0
```

After milestone 3:

```console
$ nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/language-legacy.keiro --min-language 4 --report-out /tmp/check-report.json; echo "exit=$?"
…
exit=1

$ jq '{schema, kind, ok, errors: .summary.errors, code: .diagnostics[0].code}' /tmp/check-report.json
{
  "schema": "keiro-dsl/check-report/1",
  "kind": "source",
  "ok": false,
  "errors": 1,
  "code": "LanguageVersionBelowMinimum"
}
```

During each milestone, run the focused suite with the final Hspec descriptions chosen by the
implementation (record them in Progress; the match strings below are indicative):

```console
$ nix develop -c cabal test keiro-dsl-test --test-options='--match "language contract"'
…
0 failures

$ nix develop -c cabal test keiro-dsl-test --test-options='--match "deny"'
…
0 failures

$ nix develop -c cabal test keiro-dsl-test --test-options='--match "check report"'
…
0 failures
```

Full closure after milestone 4:

```console
$ nix develop -c cabal test keiro-dsl
…
All … test suites passed

$ nix develop -c cabal build all
…

$ okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
…
validation succeeded

$ git diff --check
```

A blank `git diff --check` is success. The generated-source policy scripts
(`scripts/check-extension-policy.sh`, `scripts/check-generated-name-policy.sh`) are not part of
this closure because the plan changes no generated Haskell; the improvement-request bundle
validation is not needed because no file under `docs/improvement-requests/` changes. The
`docs/adr` strict validation is required because milestone 4 amends ADR 0004.


## Validation and Acceptance

Acceptance is behavioral:

1. Checking `keiro-dsl/test/fixtures/language-legacy.keiro` prints exactly one stderr line
   starting `keiro-dsl/test/fixtures/language-legacy.keiro: language contract:` naming
   effective version 1, `legacy-unversioned`, `compatibility-only`, and the runtime-semantics
   identifier, then `OK` on stdout with exit 0. Checking a declared language-4 fixture prints
   no such line. `scaffold` on a compatibility-only source prints the same notice; `diff`
   prints it for the working-tree side only.
2. `check --min-language 4` against any effective version below 4 exits 1 with
   `error[LanguageVersionBelowMinimum]` located at the preamble line (line 1 for
   legacy-unversioned; manifest primary plus member notes for a workspace), and prints no
   `OK`. `--min-language 1` on the same input exits 0. `--min-language 9` fails in option
   parsing, naming versions 1, 2, 3, 4.
3. A spec whose only diagnostic is a warning exits 0 by default; with `--deny-warnings` or
   `--deny <ThatCode>` it exits 1, the warning still renders as `warning[Code]` (never
   re-labelled as an error), and one `check: … escalated to failure` summary line appears.
   `--deny <OtherCode>` leaves exit 0. `--deny NotACode` is refused by the parser. Deny flags
   never change behavior for a spec with errors (already exit 1) and are absent from `scaffold`
   and `diff`.
4. `--report-out` writes a JSON document with `"schema": "keiro-dsl/check-report/1"` for both
   success and validation failure, on both the single-file and workspace paths (workspace
   reports carry `kind: "workspace"` and a members array); the document's `language`,
   `enforcement`, `diagnostics` (code/severity/file/line/message/denied/related), `summary`,
   and `ok` fields agree with the observed stderr and exit code; decoding the committed golden
   as `Value` equals the freshly produced report. No report file is created on a parse failure.
5. Every pre-existing test still passes after the deliberate stderr-assertion updates listed in
   Progress; specs declaring language 4 see byte-identical `check` stdout and stderr except
   where they carry warnings and deny flags were explicitly passed. No generated bytes, fold
   fingerprints, or scaffold outputs change (`cabal test keiro-dsl` passes without any
   conformance-fixture refresh).
6. `cabal test keiro-dsl`, `cabal build all`, the strict `docs/adr` OKF validation, and
   `git diff --check` all pass, and `docs/user/typed-spec-toolchain.md` documents the notice,
   both flags, the report schema, the CI recipe, and the warning-policy outcome.


## Idempotence and Recovery

Every new behavior is a pure function of the parsed source and the invocation flags: the
notice, floor diagnostics, deny computation, and report builder have no hidden state, so any
command or test can be re-run indefinitely. `--report-out` overwrites its target file whole via
`Aeson.encodeFile` (the same semantics as `diff --report-out`), so a partial CI run is repaired
by re-running check. The report golden is regenerated only through the public CLI; if it
drifts, regenerate and review the diff rather than hand-editing.

No database, network, wire-format, or generated-code migration is involved. The one
compatibility-sensitive change is additive stderr output for compatibility-only sources, which
is confined to milestone 1 and reverted by reverting that milestone's commits; to back out an
incomplete implementation, revert only the files this plan touched (`keiro-dsl/app/Main.hs`,
`keiro-dsl/src/Keiro/Dsl/Validate.hs`, `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs`,
`keiro-dsl/src/Keiro/Dsl/CheckReport.hs`, `keiro-dsl/keiro-dsl.cabal`, `keiro-dsl/test/Main.hs`,
new fixtures, docs, changelogs, and the ADR amendment) with an explicit patch; do not reset the
worktree. Because `DiagnosticCode` is append-only, the new constructor must not be removed once
released; before release, a revert is safe.


## Interfaces and Dependencies

No new external dependencies: `aeson`, `optparse-applicative`, `text`, and `containers` are
already direct dependencies of the `keiro-dsl` library and executable. No Keiki interface is
touched, and no Cabal bound changes.

Interfaces that must exist at the end of each milestone (exact field prefixes may follow local
style; information content and locations are fixed):

Milestone 1 — `Keiro.Dsl.SemanticContract` exports:

```haskell
languageContractNotice :: FilePath -> Text -> EffectiveLanguageContract -> Maybe Text
```

`Keiro.Dsl.Validate` appends the constructor `LanguageVersionBelowMinimum` at the end of
`DiagnosticCode` and exports:

```haskell
minimumLanguageDiagnostics :: LanguageVersion -> SourceLanguage -> [Diagnostic]
```

`keiro-dsl/app/Main.hs` replaces `Check FilePath Bool Bool (Maybe CheckCoverageOptions)` with
`Check FilePath CheckOptions` where `CheckOptions` carries emit, explain-bindings, coverage,
`Maybe LanguageVersion` (min language), and — after milestones 2–3 — deny and report fields.
Both `run (Check …)` and `runWorkspaceCheck` consume the record.

Milestone 2 — `Keiro.Dsl.Validate` derives `Enum` and `Bounded` for `DiagnosticCode` and
exports:

```haskell
diagnosticCodeText :: DiagnosticCode -> Text
parseDiagnosticCode :: Text -> Maybe DiagnosticCode
```

`CheckOptions` gains `checkDenyWarnings :: Bool` and `checkDenyCodes :: [DiagnosticCode]`.

Milestone 3 — new exposed module `Keiro.Dsl.CheckReport` with, at minimum:

```haskell
data CheckReportLanguage    -- source form, declared/effective versions, runtime id, support, stable flag
data CheckReportEnforcement -- min language, deny-warnings flag, deny codes
data CheckReportEntry       -- code, severity, file, line, message, denied, related notes
data CheckReport            -- kind, subject, language, enforcement, entries, summary, ok

checkReport ::
  FilePath -> SourceLanguage -> EffectiveLanguageContract ->
  CheckReportEnforcement -> [Diagnostic] -> Set DiagnosticCode -> CheckReport

workspaceCheckReport ::
  FilePath -> WorkspaceSpec -> EffectiveLanguageContract ->
  CheckReportEnforcement -> [WorkspaceDiagnostic] -> Set DiagnosticCode -> CheckReport
```

with a `ToJSON CheckReport` instance emitting `"schema": "keiro-dsl/check-report/1"`, and
`CheckOptions` gaining `checkReportOut :: Maybe FilePath`. The `Set DiagnosticCode` argument is
the effective deny set so `denied` flags and `summary.deniedWarnings` are computed in one
place. `keiro-dsl/keiro-dsl.cabal` lists the module under `exposed-modules`.

Milestone 4 — no code interfaces; the deliverables are `docs/user/typed-spec-toolchain.md`, the
ADR 0004 amendment plus `docs/adr/log.md`, `CHANGELOG.md`, and `keiro-dsl/CHANGELOG.md`.
