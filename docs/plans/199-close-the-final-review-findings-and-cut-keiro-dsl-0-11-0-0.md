---
id: 199
slug: close-the-final-review-findings-and-cut-keiro-dsl-0-11-0-0
title: "Close the final-review findings and cut keiro-dsl 0.11.0.0"
kind: exec-plan
created_at: 2026-08-05T22:15:31Z
intention: "intention_01kz9zxm0ferqr0z8kfm98775s"
---

# Close the final-review findings and cut keiro-dsl 0.11.0.0

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The 2026-08-05 final pre-release review (five adversarial review tracks plus an empirical
re-scaffold of the mori adopter workspace) confirmed the stabilization wave is sound where it
matters — wire keys byte-identical, fold fingerprints unmoved, check/scaffold refusal parity
real — and produced a finite defect list. This plan fixes **all** of it, including the
"accepted-and-silent" spec surfaces that were previously parked as descriptive-only, and then
cuts the coordinated 0.11.0.0 release. The owner decided explicitly: nothing ships
accepted-and-silent; the breaking window is open now, so surfaces the runtime does not
implement get refused now rather than churning adopters later.

After this plan: `keiro-dsl check --deny-warnings` is an honest CI gate (no warning class
escapes it, no never-emittable code is accepted); every spelling the grammar accepts is either
enforced, refused, or provably descriptive-and-true; the Hackage-shipped changelog tells the
whole 0.11.0.0 story; the corpus tooling cannot silently drop a suite from coverage; the
`keiro-dsl-authoring` skill teaches the released contract; and keiro-core/keiro/keiro-dsl
0.11.0.0 are tagged with keiki 0.9.0.0 published from its Hackage candidate so the mori
conversion can resume against released artifacts.

Observable outcome: `just verify` green; a scripted mori-workspace simulation (check +
refuse/apply/scaffold in a scratch copy) exits clean with zero new diagnostics and
byte-identical golden events; and `cabal build` of a fresh scratch project depending on
`keiro-dsl ==0.11.0.0` solves from Hackage alone.


## Progress

- [x] M1: package changelog completed (sidecar→ledger + record-field additions), stale docs
      corrected (ADR 0020, typed-spec-toolchain legacy-apply path, test README).
      *(2026-08-05)* `keiro-dsl/CHANGELOG.md` [Unreleased] gained six Breaking Changes
      bullets: the three on-disk sidecar renames with Cabal-fragment authority, the
      `Refusal`/`ScaffoldReport`/`WorkspaceScaffoldReport` surface plus the two newly
      exposed modules, the `keiro-dsl conformance ledger v1` format change, the
      `AggregateField`/`ContractField` record-field additions, the
      `RouterReadModelUnverified` repurposing, and the
      `ProcessBenignInversion`→`RouterBenignInversion` deny-list note. ADR 0020 gained a
      dated amendment (history preserved), `docs/user/typed-spec-toolchain.md` and
      `keiro-dsl/test/README.md` moved to ledger/Cabal-fragment vocabulary. `okf validate`
      strict: "OK: 22 concepts".
- [x] M2: CI gate integrity — deny policy covers coverage warnings, `--deny` rejects
      never-emittable codes, workspace composition refusals write the check report,
      `--report-out` creates parent dirs, one severity vocabulary across reports,
      `EmitDeriveHoleUnrealized` removed. *(2026-08-05)* All six landed;
      `keiro-dsl-test` 603 examples / 0 failures. Coverage findings are now planned
      before the deny decision and emitted with the other diagnostics (ahead of
      `--emit`/`--explain-bindings` output rather than after), so one warning policy
      governs every warning `check` can emit. `--deny` is backed by the new
      `diagnosticOrigin` registry in `Validate.hs`.
- [x] M3: inert surfaces refused/enforced — decode body posture, process `dispatch-id`
      parser parity, `on-appended` arm, timer `not-mine` arm, intake bind header names,
      workqueue required-by-default, workspace scaffold-report inert-node parity, and the
      EP-197 descriptive-only trio (timer dead-letter text, pgmq fanout function, pgmq
      dedupe key) re-adjudicated; ADR 0004 inventory re-amended. *(2026-08-05)* Eight
      surfaces closed on the warn-at-3 / error-at-4 tiering via a new `mkSurfaceRefusal`
      helper; `wqfRequired` and `WqFieldOptionalUnsupported` removed as provably constant;
      `wsrInertNodes` gives workspaces the single-spec `no-modules:` line. The canonical
      envelope headers are *imported* from `keiro-core`'s `Keiro.Integration.Event` (no
      mirror, no drift); the `TimerStatus` vocabulary is mirrored and guarded by a new
      `keiro-dsl-runtime-vocabulary-test` suite that depends on both packages. mori still
      checks exit-0 at its five-warning baseline; corpus regeneration produced no
      generated-output drift.
- [x] M4: wire/alias hardening — `contract-reserved-family.keiro` wired into a CLI test,
      wire-key content validation, collision-planner selector normalization fixed.
      *(2026-08-05)* All three landed with tests; ADR 0021 and the user docs gained the
      case-convention exemption and the structural-validation rules. See the M4 note in
      Surprises for what the collision fix does and does not change.
- [x] M5: tooling hardening — corpus plan cross-checked against the cabal suite list,
      `regenerate` dirty-tree guard, conformance-ledger orphan migration, truthful sidecar
      refusal text, `-Werror` on corpus components, Justfile `haskell-test` actually runs
      every suite. *(2026-08-05)* Root cause of the under-testing: a bare package name is a
      single-component cabal target, so `cabal test keiro-dsl` selected only
      `keiro-dsl-test`; `keiro-dsl:tests` expands to all 38. keiro, keiro-pgmq, and jitsurei
      each declare exactly one suite, so only keiro-dsl was affected.
- [x] M6: `agents/skills/keiro-dsl-authoring` refreshed to the released contract.
      *(2026-08-05)* LOOP.md, SKILL.md, and NOTATION.md moved to ledger/Cabal-fragment
      names, dropped the two removed diagnostic codes, and gained: the canonical
      `--min-language 4 --deny-warnings --report-out` CI recipe with the deny-set rules, the
      warn-at-3/error-at-4 tiering and which spelling to write, both refuse→apply migration
      flows plus the applied-renames note, the three-namespace field aliases with the
      brownfield-key guidance, and the compatibility-only stderr notice. Verified by running
      the LOOP end to end against `keiro-dsl new aggregate` in a scratch tree.
- [ ] M7: release — lockstep 0.11.0.0 bumps + bounds, corpus regeneration, changelog
      finalization, keiki 0.9.0.0 candidates published, mori simulation re-run, tag.


## Surprises & Discoveries

- (Pre-plan, 2026-08-05) keiki 0.9.0.0 and keiki-codec-json 0.9.0.0 exist on Hackage only as
  **candidates** (HTTP 200 at `/package/keiki-0.9.0.0/candidate`, 404 at the release URL;
  `/package/keiki/preferred` still lists 0.8.0.0 as latest). Candidates are not in the
  package index, so index-state–pinned consumers (mori) cannot solve against them until they
  are published. M7 depends on that publish.
- (M2, 2026-08-05) **The plan's premise for the severity-vocabulary change was wrong.** M2
  asserted "since the coverage report is new in this release, this is not a compat break".
  `--coverage-report` and `Keiro.Dsl.Coverage` actually shipped in **0.4.0.0** (2026-07-28,
  `keiro-dsl/CHANGELOG.md:720`), so `keiro-dsl/coverage-report/1` has spelled Warning as
  `"advisory"` across four released versions. Renaming it to `"warning"` is a genuine
  breaking change for any consumer matching that literal. The change still lands — the
  owner's one-vocabulary mandate holds and the breaking window is open — but it is recorded
  under Breaking Changes rather than as a silent unification.
- (M3, 2026-08-05) **The plan named the wrong tuple for process `dispatch-id`.** M3 said to
  give the process line "the router-grade parser — require `uuidv5` and the exact 5-tuple,
  reusing `pRouterDispatchIdLine`'s components". The two runtimes key on *different* fixed
  tuples: `Keiro.ProcessManager.deterministicCommandId`
  (`keiro/src/Keiro/ProcessManager.hs:406-419`) uses
  `(managerName, correlationId, sourceEventId, emitIndex)` while
  `Keiro.Router.deterministicRouterCommandId` (`keiro/src/Keiro/Router.hs:161-175`) uses
  `(routerName, key, sourceEventId, targetStreamName, occurrence)`. All 13 process fixtures
  already write the 4-tuple. Reusing the router parser verbatim would have refused every
  correct process spec while accepting a line that misdescribes the runtime. Implemented as
  a shared `pFixedDispatchIdLine :: [Text] -> P ()` with each caller pinning its own
  runtime-owned tuple — parser *parity* (the plan's actual intent) without conflating the
  two derivations.
- (M3, 2026-08-05) The timer runtime has **no not-mine branch at all**.
  `Keiro.Timer.runTimerWorkerWith` (`keiro/src/Keiro/Timer.hs:120-161`) takes a
  `TimerRow -> Eff es (Maybe EventId)`: `Just` marks the timer `Fired`, `Nothing` leaves it
  `Firing` for a later requeue. So a not-mine dispatch, having no appended event id, can only
  be retried — `not-mine Fired` is unreachable and `not-mine Retry` is exactly true. All 13
  timer fixtures already write `Retry`, so refusing `Fired` closes the surface without
  touching a single existing spec.
- (M7, 2026-08-05) **The mori simulation passes on every stated criterion**, run against
  commit `79522fec` in a scratch copy: `check domain/mori.keiro-workspace` exits 0 with
  exactly the five baseline `ReplayOnlyCommandStillLive` warnings and no new diagnostic;
  scaffold refuses with `error: sidecar migration required; nothing was written`; the rerun
  with `--apply-name-migrations` exits 0; and all **162 golden event files are byte-identical**.
  The generated Haskell *does* differ from mori's committed tree (100 of 359 files differ at
  token level), which is expected rather than a regression: mori's tree was scaffolded by a
  pre-wave keiro-dsl, and MasterPlan 29 deliberately changed generated output
  (usage-conditional imports, complete behavior-contract signatures, named sample constants).
  Verified non-alarming two ways — the **set** of string literals across every generated
  `Codec.hs` is identical (only per-key occurrence counts move, from the import/decoder
  restructuring), and the goldens prove encoded bytes are unchanged empirically. This is
  precisely why the mori upgrade sequence requires re-scaffold + recompile + conformance.
- (M6, 2026-08-05) The LOOP dry-run surfaced a defect the plan had not listed: the scaffold
  report still labelled its two sidecar lines `manifest:` and `record:` while printing paths
  to `keiro-dsl-cabal-fragment.*` and `keiro-dsl-ledger.*`. Relabelled to `fragment:` and
  `ledger:` on both the single-spec and workspace renderers, and recorded as a breaking
  stderr change. (`WorkspaceRecord.hs`'s `manifest: ` is a *persisted row key*, not a report
  label, and was deliberately left alone.) M6's acceptance grep as written
  (`grep -rn "scaffold-record\|manifest\|…"` returning nothing) is over-broad and cannot be
  satisfied: "manifest" is still the correct word for a `.keiro-workspace` manifest, and the
  legacy sidecar names must be named in the migration guidance so an author recognizes what
  they are holding. The precise check — no stale *code* names and no legacy sidecar name used
  as if current — does pass.
- (M5, 2026-08-05) The new corpus suite-coverage check immediately found two directories the
  first (over-broad) version flagged, and both were legitimate: `conformance-codec-compare`
  is a wholly hand-written suite with fixtures and no generated output, and
  `conformance-service-package/runtime/src` is compiled by its own
  `keiro-dsl-conformance-service-runtime.cabal` rather than by a keiro-dsl test-suite —
  the same exception `checkCabalInventory` already carries. The check was narrowed to flag a
  directory only when it actually contains banner-carrying generated Haskell. Proven to work
  by deleting `conformance-queue`'s ledger: the check fails naming
  `test:keiro-dsl-conformance-queue`.
- (M5, 2026-08-05) The first orphan-conformance-record scan descended into
  `.keiro-dsl-name-migrations/`, the backup root where a *retired* legacy record lives
  permanently by design. That made every subsequent run plan a migration of its own backup —
  caught by the existing lossless-conversion test, which started failing with a
  backup-of-a-backup path. The scan now skips that root.
- (M4, 2026-08-05) **The collision-planner fix does not make any previously-refused spec
  scaffold.** Finding 15's acceptance said "the previously-false-refusal spec now checks OK
  and scaffolds a compiling record". It cannot: the divergence between the planner's
  camelized rendering and generation's raw selector only arises for a name that is *not*
  lowerCamelCase, and such a name is independently refused by the generated-name audit.
  Verified empirically — `{foo_bar, fooBar}` before the fix reported both a
  `GeneratedOccurrenceCollision` and `GeneratedPlanningInvariantViolation` ("generated
  declaration 'foo_bar' is not lowerCamelCase"); after the fix only the second remains. So
  the fix's real value is that the author now gets the accurate diagnostic instead of a
  false claim about an unrelated sibling, and the collision registry now mirrors generation
  exactly so it stays correct if the naming rules change. Genuine collisions (two
  declarations that really do emit one selector) are still caught — asserted in the test.
- (M2, 2026-08-05) The `--deny` emittable-set registry could not be derived from severity, so
  it was derived mechanically from the sources: for each of the 301 `DiagnosticCode`
  constructors, count its mentions in `Validate.hs` (exactly one = the enum declaration, so
  the validator never emits it) and list which other modules mention it. That partitions
  cleanly into 93 diff-only codes, 3 codec-comparison codes, `CoverageOpaqueSurface` /
  `CoverageOpaqueGateExceeded` (check-reachable coverage), `CoverageOpaqueBoundaryAdded`
  (diff-coverage only), and the rest check-emittable — including the five `ScaffoldRun`
  planning codes, which `check` does emit because it replays the scaffold planner.
- (Pre-plan, 2026-08-05) `cabal test keiro-dsl` runs **only** `keiro-dsl-test` ("1 of 1 test
  suites") despite the package declaring 37 test-suites and the Justfile comment claiming
  otherwise; the 36 conformance/auxiliary suites only run when named individually. Root cause
  to be confirmed in M5; until fixed, `just haskell-test` under-tests the package.


## Decision Log

- Decision: Close the remaining inert surfaces by **refusing or enforcing now**, not by
  implementing new runtime semantics.
  Rationale: Owner's explicit call (2026-08-05): the release exists to prevent churn; the
  breaking window is open; every accepted-and-silent spelling is a future forced break. New
  runtime features (lenient decoding, configurable dispositions, header remapping) are out of
  scope and can be added later behind spellings that only start being accepted when they work.
  Date: 2026-08-05
- Decision: Release execution (version bumps, corpus regen, keiki publish, tag) is this
  plan's final milestone rather than a separate plan.
  Rationale: Owner's call; the release is the exit criterion for the whole stabilization
  effort, and every earlier milestone regenerates the corpus banner anyway.
  Date: 2026-08-05
- Decision: Remove the `EmitDeriveHoleUnrealized` diagnostic entirely (constructor and
  emission) instead of demoting or docs-patching around it.
  Rationale: It fires unconditionally on every emit node because the `derive … hole` syntax
  is mandatory grammar (`keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs:178-182`), so it
  carries zero information, and it makes the documented CI recipe (`check --deny-warnings`,
  `docs/user/typed-spec-toolchain.md:1633-1638`) permanently red for any emit-bearing
  service. The scaffold report's no-modules line and the docs sentence already carry the
  fact. Removing a `DiagnosticCode` constructor in the 0.11.0.0 breaking window follows the
  precedent of the four constructors removed by EP-197.
  Date: 2026-08-05
- Decision: Wire-key aliases are **exempt** from a declared `wire … fields=camelCase`
  convention; validation of alias content is limited to structural safety (non-empty, no
  leading/trailing whitespace, no control characters).
  Rationale: Aliases exist precisely to preserve brownfield wire keys that violate the
  current convention (`region_code` in the shipped fixture
  `keiro-dsl/test/fixtures/aggregate-field-alias.keiro` is the canonical example). Checking
  aliases against the convention would defeat their purpose. Whitespace/control validation
  closes the real trap (a typoed `as "family "` shipping a permanently mis-keyed public
  field) without opinionating on key style. Document the exemption in ADR 0021's validation
  rules and the user docs.
  Date: 2026-08-05
- Decision: Keep the hard refusal of guarded live sibling transitions on the same
  (source, command) pair introduced by the transition-identity unification
  (`aggregateHarnessOccurrences`, `keiro-dsl/src/Keiro/Dsl/Validate.hs:1408-1447`).
  Rationale: The pre-0.11 behavior generated colliding harness declarations that failed at
  adopter compile time — the refusal is strictly more honest, and no mori aggregate has
  duplicate pairs. If the shape is ever needed, uniquifying probe names is a compatible
  follow-up.
  Date: 2026-08-05
- Decision (M3): Remove `WqField`'s `wqfRequired` rather than defaulting it to `True`.
  Rationale: With required-by-default and no optional spelling in the grammar, the field is
  provably constant. A constant record field is exactly the accepted-and-silent shape this
  plan exists to eliminate, and leaving it would strand two unreachable `Diff.hs` branches
  (optional→required, required→optional). The `required` keyword stays accepted so existing
  sources parse, and the pretty-printer always emits it, which keeps every corpus fixture's
  canonical rendering byte-identical. Consequence: adding a payload field is now classified
  breaking however it is spelled — correcting a prior "new optional field is additive"
  classification that described a decoder keiro-dsl never generated.
  Date: 2026-08-05
- Decision (M3): Report the pgmq `dedup key` refusal with the existing
  `DispatchReadModelFieldUnknown` rather than minting a new code.
  Rationale: The plan called for "a new lang-4-tiered code", but this is literally the same
  defect the code already names — a dispatch referencing a read-model field that does not
  exist — with the same remedy. Two codes for one failure class would make an adopter's
  `--deny` list and triage worse, not better. The two other trio surfaces did get new codes
  (`TimerDecodeStatusUnknown`, `TimerDeadLetterTextInvalid`) because no existing code covers
  them, as did `PgmqFanoutFunctionInvalid`.
  Date: 2026-08-05
- Decision (M3): Keep the timer `dead-letter` **text** descriptive, and close it only by
  refusing a blank reason — a narrower closure than the other seven surfaces.
  Rationale: Unlike every other surface here, there is no correct spelling to accept and no
  referent to resolve: it is free prose. It is not inert, though.
  `Keiro.Timer.runTimerWorkerWith` composes its own message for the attempt ceiling, but
  `Keiro.Timer.deadLetterTimer` is public and the generated timer hole renders this text
  precisely so an operator-written worker can pass it. That makes it a hand-owned obligation
  of the same kind as `derive … hole`, and the checkable part is that it names an obligation
  at all. Making the runtime consume it would be new runtime semantics, which this plan
  excludes.
  Date: 2026-08-05
- Decision (M3): Emit `source`/`key`/map-discriminant names remain the single
  documented descriptive-only surface (the exception ADR 0004 row 122 already carries).
  Rationale: The structural reason the plan anticipated is real and unchanged — an emit
  generates no module, so no typed source namespace exists to resolve these names against,
  and there is no decidable property to check beyond what the parser already enforces. Every
  other parked surface did turn out to have a checkable referent and was closed.
  Date: 2026-08-05
- Decision (M2): Default an unclassified `DiagnosticCode` to check-emittable in
  `diagnosticOrigin` (a `_ -> CheckDiagnostic` fallthrough) rather than forcing an
  exhaustive 301-arm table.
  Rationale: The two failure directions are not symmetric. Wrongly classifying a code as
  non-check *rejects a working adopter CI invocation*; wrongly falling through merely
  preserves the pre-199 behavior of accepting it. Only codes positively proven non-check by
  the source survey are listed, so the registry is sound in the direction that matters.
  Date: 2026-08-05
- Decision (M2): Coverage output moves ahead of `--emit`/`--explain-bindings` output.
  Rationale: Gating coverage requires knowing its findings before the exit decision, and a
  denied run must not print success-path artifacts. Treating coverage as a diagnostic pass
  rather than a success-path artifact is the only ordering that makes both true. Reports and
  the `OK` line keep their existing relative order, so the common invocations are unchanged.
  Date: 2026-08-05
- Decision (M2): Model a composition-refused workspace report with
  `reportLanguage :: Maybe CheckReportLanguage` serialized as `"language": null`.
  Rationale: No service graph was composed, so no effective language contract exists to
  describe; inventing one would put a false fact in a machine contract. No existing consumer
  regresses because this report previously did not exist at all. Rejected alternatives: a new
  `kind` value (widens an existing enum for every consumer) and omitting the key (a reader
  cannot distinguish "absent" from "old writer").
  Date: 2026-08-05
- Decision (M1): Leave `keiro-dsl/test/README.md:44` saying "record/disk consistency"
  unchanged while moving the rest of the file to ledger vocabulary.
  Rationale: That phrase quotes the corpus driver's literal stdout
  (`keiro-dsl/tools/corpus-regen/src/Main.hs:132` prints `record/disk consistency: ok`).
  Renaming the prose without renaming the emitted string would replace one doc/reality
  mismatch with another. If the tool's output string is ever renamed, this line follows it.
  Date: 2026-08-05
- Decision: Parked (recorded, deliberately not in scope): (a) compiling all 107
  `uncompiled-generated` corpus exemptions — mitigated because polish is generator-side and
  the exemption list refuses stale/unknown entries; the `-Werror` change in M5 hardens the
  compiled subset; (b) transactional sidecar moves — the moves are idempotent and
  forward-consistent, so M5 fixes the lying refusal text instead; (c) a non-breaking path
  for wire-preserving DSL-name renames (`family` → `familia as "family"` classifies as
  replay-affecting) — over-strict but errs safe, consistent with ADR 0021's "DSL name is
  identity", and no adopter needs it today.
  Date: 2026-08-05


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

**What this repository is.** keiro is a Haskell event-sourcing service framework; the
`keiro-dsl` package (under `keiro-dsl/`) is its spec-driven toolchain: authors write typed
`.keiro` specifications, `keiro-dsl check` validates them, `keiro-dsl scaffold` generates the
deterministic Haskell layer plus explicit typed holes, and `keiro-dsl diff` gates evolution
(wire compatibility, replay impact). The flagship adopter is mori
(`/Users/shinzui/Keikaku/bokuno/mori-project/mori`, canonical handle `mori://shinzui/mori`),
whose committed workspace is `domain/mori.keiro-workspace` with ten `.keiro` members, all
declaring `language keiro-dsl 4`.

**Where this plan comes from.** MasterPlan
[docs/masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md](../masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md)
(EP-190…EP-198) implemented the 2026-08-04 pre-adoption audit. A final adversarial review on
2026-08-05 (five parallel tracks over `ba9ffefd..98f19e46` plus an empirical mori
re-scaffold) verified the wave and produced the findings this plan closes. Verified-good and
therefore **not** in scope: wire-key preservation (unaliased fields emit identical bytes;
mori's `family` field keeps selector and `"family"` wire key), fold-fingerprint stability
(`CanonicalEncoding`/`FoldFingerprint`/`EventOutput`/`Expression` had zero commits in the
range), refusal parity (check runs the real scaffold planner on both single-spec and
workspace paths), and the sidecar migration flow (refuse → `--apply-name-migrations` → apply
with backups, hand-written files untouched).

**Key terms.**
- *Diagnostic code*: a constructor of `DiagnosticCode` in
  `keiro-dsl/src/Keiro/Dsl/Validate.hs`, serialized by `Show` name (never Enum index), with
  severity Warning or Error. Language-4 "strict spec-surface validation" errors are gated by
  `enforcesSpecSurfaceClosures` (`Validate.hs:509-511`); warnings are ungated.
- *Deny policy*: `check --deny-warnings` / `--deny <Code>` (`keiro-dsl/app/Main.hs:335-349`)
  turns matching warnings into exit-1; the versioned JSON check report
  (`keiro-dsl/src/Keiro/Dsl/CheckReport.hs`, schema `keiro-dsl/check-report/1`) records them.
- *Ledger sidecars*: role-bearing scaffold history files
  (`keiro-dsl-ledger.*`, `keiro-dsl-cabal-fragment.*`, `keiro-dsl-conformance-ledger.txt`)
  per ADR 0022; legacy names are migrated only by `scaffold --apply-name-migrations`.
- *Corpus*: the ~34 committed generated conformance suites under `keiro-dsl/test/…`,
  regenerated by `keiro-dsl/tools/corpus-regen` (plan derivation in
  `keiro-dsl/tools/corpus-regen/src/CorpusPlan.hs`) and policed by
  `scripts/check-conformance-corpus.sh` from `just verify`.

**Relevant ADRs** (all local, under `docs/adr/`):
- [0004 — evolution changes are gated at the earliest sound boundary](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md):
  holds the landed accepted-surface inventory (line 89; row at line 123 explicitly lists
  "Intake decode posture, timer unknown-status/dead-letter text, pgmq fanout function, and
  pgmq top-level dedupe key" as descriptive-only, and line 230 says the inventory is amended
  when a child plan changes a gate's ownership). M3 flips these surfaces to
  refused/enforced; the inventory row must be re-amended in the same change.
- [0018 — runtime capability profiles and frozen fold identity](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md):
  language 4 keeps `runtimeProfileV3`; nothing in this plan may move a fold fingerprint.
- [0020 — service conformance packages import one runtime-owned facade](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md):
  line 75 still calls `keiro-dsl-manifest.*.txt` authoritative — contradicted by ADR 0022;
  M1 fixes the sentence.
- [0021 — direct fields have independent DSL selector and wire identities](../adr/0021-direct-fields-have-independent-dsl-selector-and-wire-identities.md):
  the three-identity model M4 hardens; its validation-rules section gains the
  alias-content rules and the case-convention exemption.
- [0022 — generated sidecars use role-bearing names and forward-compatible ledgers](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md):
  the rename contract whose changelog entry M1 writes.

**Finding inventory this plan closes** (source: 2026-08-05 review; anchors verified at
`98f19e46`):

1. `keiro-dsl/CHANGELOG.md` [Unreleased] omits the entire sidecar→ledger breaking change
   (only the repo-root `CHANGELOG.md` has it) and the `AggregateField`
   (`aggregateFieldSelector`/`aggregateFieldWireKey`) and `ContractField`
   (`cfSelector`/`cfWireKey`/`cfLoc`) record-field additions in
   `keiro-dsl/src/Keiro/Dsl/Grammar.hs` (exports at lines 49 and 93).
2. Coverage warnings escape the deny policy: `warning[CoverageOpaqueSurface]`
   (`keiro-dsl/src/Keiro/Dsl/Coverage.hs:270-282`, severity at `:467`) renders in the same
   `check` invocation but the deny scan (`app/Main.hs:335-349`) sees only
   `checkServiceDiagnostics` + floor diagnostics, so `--coverage-report x --deny-warnings`
   exits 0 with warnings printed; `--deny` also accepts diff-only codes check can never emit.
3. Workspace composition/planning refusals (e.g. cross-member `GeneratedPathCollision`)
   surface via `Left` from `loadWorkspace` and exit before `--report-out` is written
   (`app/Main.hs:660-664`), while the identical single-spec failure produces a report.
4. `--report-out` uses `Aeson.encodeFile` without creating parent directories
   (`app/Main.hs:369-405`); the coverage writer does (`Coverage.hs:287-290`). Coverage JSON
   serializes Warning as `"advisory"` (`Coverage.hs:616`) while the check report says
   `"warning"` — two severity vocabularies in one release.
5. `EmitDeriveHoleUnrealized` is structurally unsuppressable (see Decision Log).
6. Decode `body strict|lenient` is parse-and-ignore: `decBodyStrict` has zero consumers
   outside parser/pretty-printer; swapping the word changes nothing (proven byte-identical
   check output).
7. Process `dispatch-id` is parse-and-discard (`keiro-dsl/src/Keiro/Dsl/Parser/Coordination.hs:212-217`,
   comment "parse and discard": any strategy ident, any tuple) while the router twin
   (`pRouterDispatchIdLine`, `:117-133`) hard-requires `uuidv5` and the exact 5-tuple.
   `dispatch-id strategy=md5 from=(banana)` checks OK on a process at language 4.
8. `on-appended AckOk|Retry|DeadLetter` parses (`Parser/Coordination.hs:112,198,203-209`) but
   `onAppended` has zero consumers — `on-appended Retry` silently behaves as ack.
9. Timer-fire `not-mine Fired|Retry` is inert: `notMine` (`Grammar.hs:723`) has zero
   consumers; `FireOutcome` lowering (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs:3897-3903`) covers
   only on-ok/on-reject/on-ambiguous/on-error.
10. Intake `bind` rows: `brSource` has zero consumers and the runtime hardwires envelope
    header names (`keiro/src/Keiro/Inbox/Kafka.hs:84-85`), so
    `bind source from header "x-custom"` silently fails to remap at every language version.
11. `WqFieldOptionalUnsupported` makes the minimal spelling warn: parser defaults
    `wqfRequired = False` (`keiro-dsl/src/Keiro/Dsl/Parser/Queue.hs:96-97`) yet generated
    decoders use `o .:` (required) for every field (`Scaffold.hs:3346`), so `required` is
    de-facto mandatory syntax the grammar calls optional.
12. `reportInertNodes` exists only on the single-spec path; `WorkspaceScaffoldReport`
    (`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs:355-383`) has no inert-node field and
    renders no "no-modules" line — workspaces are the recommended layout.
13. `keiro-dsl/test/fixtures/contract-reserved-family.keiro` is referenced by no test — the
    fixture that pins the mori `family` scenario through `check` is dead.
14. Wire-key alias content is unvalidated beyond non-emptiness (`Validate.hs:3533-3537`):
    trailing-space, control-character, and escaped-newline keys are accepted silently.
15. The collision planner registers the **camelized** rendering of an implicit selector
    (`Validate.hs:1396-1400`: `foo_bar` → `fooBar`) while generation emits the raw name
    (`keiro-dsl/src/Keiro/Dsl/FieldIdentity.hs:29`), so `{foo_bar, fooBar}` in one record is
    falsely refused and the diagnostic text misdescribes generation.
16. Corpus-regen derives its plan solely from tracked ledger files
    (`CorpusPlan.hs:213-281`) and scopes both consistency checks to plan-entry out-dirs
    (`:296-347`, `:419-448`) — deleting one suite's ledger drops it from regeneration *and*
    both checks silently. `regenerate` has no dirty-tree guard (only `check` calls
    `requireCleanCorpus`, `keiro-dsl/tools/corpus-regen/src/Main.hs:61,74-80`).
17. `ScaffoldRun.hs:670` plans conformance-sidecar migration only when the run plans a
    conformance package; scaffolding without one leaves a legacy
    `keiro-dsl-conformance-record.txt` orphaned and unreadable (legacy parser removed from
    `parseConformancePackageRecord`).
18. Sidecar moves are applied before later refusal gates (`ScaffoldRun.hs:666-682`,
    `WorkspaceScaffold.hs:407-437`), so a subsequent refusal's "nothing was written" text is
    false (the renames persist — idempotent, but the message lies).
19. `agents/skills/keiro-dsl-authoring` is entirely stale: old sidecar names
    (`LOOP.md:115,142,206`, `SKILL.md:119`, `NOTATION.md:585-591`), removed codes
    `IdentHaskellKeyword`/`IdentNotConstructorSafe` listed as codes to resolve
    (`LOOP.md:52-53`), zero coverage of `--deny-warnings`/`--min-language`/`--deny`/
    `--report-out`/`--apply-name-migrations` or field aliases.
20. Stale docs: `docs/adr/0020…md:75` present-tense manifest authority;
    `docs/user/typed-spec-toolchain.md:1519` legacy-apply path says "manifest/record";
    `keiro-dsl/test/README.md:29,65` pre-rename vocabulary.
21. `common warnings` is `-Wall -Werror=missing-fields` only (`keiro-dsl/keiro-dsl.cabal:20-21`);
    a generated-output warning regression builds green.
22. `cabal test keiro-dsl` runs only the main suite (see Surprises); `Justfile:54-60`
    (`haskell-test`) therefore under-tests.
23. keiki 0.9.0.0 / keiki-codec-json 0.9.0.0 are unpublished Hackage candidates (see
    Surprises).
24. Changelog wording gaps worth one sentence each: `RouterReadModelUnverified` was a
    repurposed never-emitted constructor (new semantics), and router rows moved from
    `ProcessBenignInversion` to `RouterBenignInversion` (an adopter `--deny
    ProcessBenignInversion` list silently stops matching router rows).
25. Three more surfaces remain "explicitly descriptive-only" per ADR 0004's inventory row
    (line 123), parked there by EP-197's decision log: timer unknown-status/dead-letter
    text, the pgmq fanout function, and the pgmq top-level dedupe key. Same class as
    findings 6-10; the owner's fix-everything mandate covers them.


## Plan of Work

Milestones are ordered so validation surfaces change before the corpus is regenerated, and
the corpus is regenerated once per milestone that touches generated output. Every commit
carries `ExecPlan: docs/plans/199-close-the-final-review-findings-and-cut-keiro-dsl-0-11-0-0.md`
and `Intention: intention_01kz9zxm0ferqr0z8kfm98775s`.

### M1 — Truthful release accounting (findings 1, 20, 24)

Scope: documentation only; no behavior change. Port the two `**keiro-dsl**` sidecar→ledger
bullets from the root `CHANGELOG.md` into `keiro-dsl/CHANGELOG.md` [Unreleased] as full
breaking-change entries covering: the three on-disk renames, refuse-then-migrate behavior,
`Refusal`'s `SidecarMigrationRequired`/`SidecarMigrationRefusal`,
`ScaffoldReport.reportSidecarMoves`/`WorkspaceScaffoldReport.wsrSidecarMoves`, the
`keiro-dsl conformance ledger v1` format, and the exposed modules `Keiro.Dsl.SidecarNames`
and `Keiro.Dsl.SidecarMigration` (`keiro-dsl.cabal:41-42`). Add the `AggregateField`/
`ContractField` field-addition bullet, the `RouterReadModelUnverified` repurposing sentence,
and the `ProcessBenignInversion`→`RouterBenignInversion` deny-list note. Fix
`docs/adr/0020…md:75` (manifest authority now belongs to the Cabal fragment per ADR 0022 —
append a dated amendment note, do not rewrite history), `docs/user/typed-spec-toolchain.md:1519`,
and `keiro-dsl/test/README.md:29,65`. Acceptance: `grep -n "ledger" keiro-dsl/CHANGELOG.md`
is non-empty; a reviewer can reconstruct every exported-symbol change in the release from the
package changelog alone.

### M2 — CI gate integrity (findings 2, 3, 4, 5)

Scope: `keiro-dsl/app/Main.hs`, `Coverage.hs`, `CheckReport.hs`, `Validate.hs`, tests.
- Extend the deny scan to include coverage findings whenever coverage runs in the same
  invocation, so `--deny-warnings` (and `--deny CoverageOpaqueSurface`) gates them; the check
  report gains the denied coverage entries.
- Make `--deny <Code>` refuse (CLI parse error listing the emittable set) any code `check`
  cannot emit — the emittable set is check-severity codes plus coverage codes when coverage
  is requested; diff-only codes are named in the error text as diff-side.
- On workspace composition/planning refusal with `--report-out`, write a failing check report
  (schema unchanged — refusals become error entries) before exiting 1.
- Create parent directories in the report writer (mirror `Coverage.hs:287-290`).
- Unify severity vocabulary: coverage JSON emits `"warning"`; since the coverage report is
  new in this release, this is not a compat break. Record the field contract in the check
  automation contract doc.
- Remove `EmitDeriveHoleUnrealized` (constructor, emission in `validateEmit`, docs sentence
  at `docs/user/typed-spec-toolchain.md:1053-1054` becomes descriptive prose without a code,
  changelog bullet under Breaking Changes). Extend the CHANGELOG exhaustive-match note.
Acceptance: new tests prove (a) `check x --coverage-report r --deny-warnings` exits 1 when an
opaque surface exists, (b) `--deny EvtFieldWireKeyChanged` (diff-only) is a CLI error,
(c) a workspace path-collision run with `--report-out` writes a report with `ok:false`,
(d) `keiro-dsl new emit` output passes `check --deny-warnings` clean.

### M3 — Refuse or enforce every remaining inert surface (findings 6-12)

Scope: parser + validator + docs + ADR 0004 inventory re-amendment; language-4 gating follows
the EP-197 pattern (ungated warning, `enforcesSpecSurfaceClosures` error) unless stated.
- **Decode posture**: new code `DecodeBodyPostureUnsupported` — `body lenient` warns pre-4,
  errors at 4; `body strict` (matches generated behavior) stays accepted silently. Keep
  `decBodyStrict` parsed for diff identity.
- **Process `dispatch-id`**: replace `pDispatchIdLine` (`Parser/Coordination.hs:212-217`)
  with the router-grade parser — require `uuidv5` and the exact 5-tuple, reusing
  `pRouterDispatchIdLine`'s components; malformed lines become parse errors exactly as on
  routers. Confirm `processIdentity` diff identity still includes the parsed fields.
- **`on-appended`**: new code `DispatchOnAppendedUnsupported` — any value other than `AckOk`
  warns pre-4, errors at 4, on both router and process dispatch rows; `AckOk` (the hardwired
  runtime behavior) stays accepted.
- **Timer `not-mine`**: first read the runtime's actual not-mine handling in
  `keiro/src/Keiro/…` timer-fire path; then refuse (same warn/error tiering, code
  `TimerNotMineUnsupported`) whichever spelling(s) contradict it. If the runtime has exactly
  one behavior, accept only the matching spelling.
- **Intake `bind` header names**: new code `IntakeBindHeaderUnknown` — a `bind … from header
  "x"` whose header is not in the runtime's fixed envelope set
  (`keiro/src/Keiro/Inbox/Kafka.hs:84-85`; import the list or mirror it with a cross-repo
  test) warns pre-4, errors at 4. Rows naming the fixed headers are descriptive-and-true and
  stay silent. `IntakeBindFlagUnenforced` stays.
- **Workqueue `required`**: flip the model to required-by-default — bare fields mean required
  (matching `o .:` generation); remove `WqFieldOptionalUnsupported`; if the grammar admits an
  explicit optional spelling, refuse it at 4 with `WqFieldOptionalUnsupported` repurposed as
  an error. Fixtures already write `required`; the keyword remains accepted as a no-op.
- **Workspace inert-node parity**: add `wsrInertNodes` to `WorkspaceScaffoldReport`, populate
  from member plans, render the same "no-modules" line as the single-spec path.
- **EP-197's descriptive-only trio** (finding 25): re-adjudicate under the fix-everything
  rule. For each of timer unknown-status/dead-letter text, pgmq fanout function, and pgmq
  top-level dedupe key: read the runtime/generation path it purports to describe; if the
  referenced name/value is checkable (a function that must exist, a field that must resolve,
  text the runtime actually uses), enforce reference validity with a new lang-4-tiered code;
  if the runtime genuinely ignores it, refuse divergent values the same way as `on-appended`.
  The one surface allowed to remain documented-descriptive is emit source/key/discriminant
  names (ADR 0004 row 122), which has a structural reason — no typed source namespace exists
  yet; record that exception in the Decision Log when reached.
Update `docs/user/typed-spec-toolchain.md` (remove "descriptive-only today" sentences that no
longer hold: `:1015-1018` decode posture, `:994-1001` bind rows, `:852-854` stays for
`decode unknown-status`/dead-letter text unless also closed — verify each), re-amend the
ADR 0004 inventory, changelog bullets for every new/removed code.
Acceptance: for each surface, a mutated fixture that previously checked OK now warns at
language 3 and errors at language 4 (new tests, EP-197 style); mori's workspace still checks
exit-0 with zero new diagnostics (its specs use none of the refused spellings — verify,
don't assume); full suite + corpus regen green.

### M4 — Wire/alias hardening (findings 13, 14, 15)

- Wire `contract-reserved-family.keiro` into `keiro-dsl/test/Main.hs` as a CLI check-path
  test: exit 0, no diagnostics, and (scaffold to temp) the generated codec contains selector
  `family` and wire key `"family"`.
- Extend `FieldWireKeyInvalid` (`Validate.hs:3530-3563`): refuse empty (existing), leading or
  trailing whitespace, and any control character in alias keys, with the offending codepoint
  named. Per the Decision Log, no case-convention check — add the exemption sentence to
  ADR 0021 and the user docs.
- Fix the collision planner to register the **raw** implicit selector exactly as
  `FieldIdentity.hs:29` emits it, so `{foo_bar, fooBar}` stops being falsely refused, and
  correct the diagnostic's "normalizes to" text. Add a regression test with that exact pair.
Acceptance: new unit tests for each rejected alias shape; the previously-false-refusal spec
now checks OK and scaffolds a compiling record.

### M5 — Tooling hardening (findings 16, 17, 18, 21, 22)

- `CorpusPlan.hs`: derive an expected-suite set from `keiro-dsl/keiro-dsl.cabal` test-suite
  stanzas (parse the file; no Cabal library needed for stanza names + hs-source-dirs) and
  fail `check` when a conformance suite directory has no plan entry or vice versa.
- `Main.hs` (corpus-regen): `regenerate` calls `requireCleanCorpus` too; add
  `--allow-dirty` for intentional local iteration. On a failing `check`, print the exact
  `git checkout -- <dirs>` recovery line.
- Conformance-ledger orphan: in `ScaffoldRun.hs` (and the workspace twin), plan the
  conformance-sidecar migration whenever a legacy `keiro-dsl-conformance-record.txt` exists
  in the out tree, independent of whether this run plans a conformance package.
- Truthful refusal text: when prepared sidecar moves were applied and a later gate refuses,
  the refusal says "sidecar renames were applied (idempotent); no other files were written"
  — both paths (`ScaffoldRun.hs:666-682`, `WorkspaceScaffold.hs:407-437`).
- Add `-Werror` to the `generated-output` common stanza so corpus components fail on any
  future generated-warning regression (keep `-Wall` in `warnings` unchanged for src).
- Fix `just haskell-test`: diagnose why `cabal test keiro-dsl` selects one suite (likely
  target-resolution semantics); replace with an enumerating loop or `cabal test` per suite
  so all 37 run; update the Justfile comment to match reality.
Acceptance: deleting a suite's ledger makes `corpus-regen check` fail naming the suite;
`regenerate` on a dirty corpus refuses without `--allow-dirty`; `just haskell-test` output
shows all keiro-dsl suites; full corpus check byte-clean.

### M6 — Authoring skill refresh (finding 19)

Rewrite the stale sections of `agents/skills/keiro-dsl-authoring/` (SKILL.md, LOOP.md,
NOTATION.md): ledger sidecar names and the refuse→`--apply-name-migrations` flow; the
current diagnostic-code workflow (removed codes deleted from the resolve list; new codes with
their language-4 tiering); `--min-language 4 --deny-warnings --report-out` as the canonical
CI invocation (now honest after M2); field aliases (`haskell <selector>` / `as "<wire-key>"`)
with the brownfield-key guidance from ADR 0021; the language-contract stderr notice.
Acceptance: `grep -rn "scaffold-record\|manifest\|IdentHaskellKeyword\|IdentNotConstructorSafe" agents/skills/keiro-dsl-authoring/`
returns nothing; a dry-run of the LOOP against a scratch spec exercises only current flags.

### M7 — Release (findings 23 + procedure)

- Publish the keiki 0.9.0.0 and keiki-codec-json 0.9.0.0 Hackage candidates (owner action —
  candidate pages `/package/keiki-0.9.0.0/candidate` and
  `/package/keiki-codec-json-0.9.0.0/candidate`; "publish" on each). Then verify
  `curl -s https://hackage.haskell.org/package/keiki/preferred` lists 0.9.0.0.
- Lockstep bump: keiro-core, keiro, keiro-dsl `version: 0.11.0.0`; move internal bounds
  (`keiro-dsl.cabal:117`, `keiro.cabal:126,194`, `keiro-pgmq.cabal:62,90`) to `^>=0.11.0.0`;
  decide keiro-pgmq/keiro-migrations own bumps from their changelog state during execution.
- Full corpus regeneration (the version banner — `Scaffold.hs:6614` via `Paths_keiro_dsl` —
  is embedded in 379 committed files): `just corpus-regen`, then `just verify`.
- Changelog finalization: `[Unreleased]` → `[0.11.0.0] - <date>` in each released package.
- Re-run the mori simulation (Concrete Steps below) against the release commit: check exit 0,
  scaffold refuse→apply→success, golden events byte-identical, zero new diagnostics.
- Tag (`keiro-dsl-0.11.0.0` plus sibling tags per repo convention — confirm from `git tag`
  history), push, and record the mori upgrade sequence in the release notes: bump
  `Justfile:130,134` tool pin, `cabal.project:5` index-state past the upload, nix overlay
  versions/hashes (`nix/haskell-overlay.nix:172,190-191`), keiki bounds `^>=0.8` → `^>=0.9`
  in `mori-core.cabal:430,687` / `mori-cli.cabal:140,240`, then scaffold (expect
  `SidecarMigrationRequired`), rerun with `--apply-name-migrations`, recompile, run
  conformance.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless noted.

Build and test (fast loop while iterating on a milestone):

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test            # main suite (598+ examples)
```

Full-suite run (until M5 fixes `just haskell-test`, enumerate):

```bash
for s in $(grep -E "^test-suite" keiro-dsl/keiro-dsl.cabal | awk '{print $2}'); do
  cabal test "$s" || { echo "FAIL $s"; break; }
done
```

Corpus regeneration and policy (after any generated-output change):

```bash
just corpus-regen
cabal run -v0 keiro-dsl-corpus-regen -- check   # expect: "conformance corpus: ok"
just verify
```

Mori adopter simulation (scratch copy; never touches the mori tree). Expected transcript
shape shown from the 2026-08-05 run:

```bash
SIM=$(mktemp -d)/mori-sim && mkdir -p "$SIM/mori-core/test/fixtures/golden"
cp -R /Users/shinzui/Keikaku/bokuno/mori-project/mori/domain "$SIM/"
cp -R /Users/shinzui/Keikaku/bokuno/mori-project/mori/mori-core/src "$SIM/mori-core/"
cp -R /Users/shinzui/Keikaku/bokuno/mori-project/mori/mori-core/test/fixtures/golden/events \
      "$SIM/mori-core/test/fixtures/golden/"
BIN=$(cabal list-bin keiro-dsl | tail -1)
cd "$SIM"
"$BIN" check domain/mori.keiro-workspace            # expect exit 0; only ReplayOnlyCommandStillLive warnings
"$BIN" scaffold domain/mori.keiro-workspace --out mori-core/src \
       --goldens mori-core/test/fixtures/golden/events
# expect exit 1: "error: sidecar migration required; nothing was written" + rename list
"$BIN" scaffold domain/mori.keiro-workspace --out mori-core/src \
       --goldens mori-core/test/fixtures/golden/events --apply-name-migrations
# expect exit 0; then goldens byte-identical:
diff -rq /Users/shinzui/Keikaku/bokuno/mori-project/mori/mori-core/test/fixtures/golden/events \
         mori-core/test/fixtures/golden/events    # expect: no output
```

Hackage verification (M7, after publishing the candidates):

```bash
curl -s https://hackage.haskell.org/package/keiki/preferred -H "Accept: application/json"
# expect "0.9.0.0" in normal-version
```

Commit template:

```text
<type>(dsl): <subject>

<body>

ExecPlan: docs/plans/199-close-the-final-review-findings-and-cut-keiro-dsl-0-11-0-0.md
Intention: intention_01kz9zxm0ferqr0z8kfm98775s
```


## Validation and Acceptance

Per-milestone acceptance is stated inline in Plan of Work. Plan-level acceptance, in order:

1. `just verify` passes: all keiro-dsl suites (37+, including any tests added here), corpus
   byte-clean, generated-source policies green.
2. `keiro-dsl check <spec> --deny-warnings` is demonstrably honest: an emit-bearing skeleton
   (`keiro-dsl new emit`, then `new intake`) checks clean; an opaque-coverage spec with
   `--coverage-report` fails; a diff-only `--deny` code is a CLI error.
3. Every M3 surface has a red/green fixture pair: the refused spelling errors at language 4
   (warns at 3) with a named code and source line; the accepted spelling is silent.
4. The mori simulation passes end-to-end with **zero new diagnostics** relative to the
   2026-08-05 baseline (5× ReplayOnlyCommandStillLive only) and byte-identical goldens.
5. `keiro-dsl/CHANGELOG.md` alone reconstructs the release: every exported-symbol change,
   every new/removed diagnostic code, the ledger renames, the migration flags.
6. After M7: `keiki 0.9.0.0` resolves from Hackage; keiro-core/keiro/keiro-dsl 0.11.0.0
   tagged; a scratch `cabal.project` pinning an index-state after the uploads solves
   `keiro-dsl ==0.11.0.0` without source-repository stanzas.


## Idempotence and Recovery

- Milestones M1-M6 are ordinary commits on `master`; each leaves `just verify` green and can
  be reverted independently. Commit after every finding-cluster, not once per milestone.
- Corpus regeneration is deterministic and idempotent (proven byte-identical on repeated
  runs); if a regen goes wrong, `git checkout -- keiro-dsl/test` restores, then rerun.
- The mori simulation always runs in a fresh scratch directory; it cannot affect the mori
  checkout. Never point `--out` at the real mori tree from this plan.
- M7 order matters: publish keiki candidates **before** tagging keiro (a keiro 0.11 tag whose
  bounds cannot solve on Hackage is the failure mode this ordering prevents). Version-bump +
  corpus-regen must land in one commit or `just verify` is red between them.
- If a language-4 refusal added in M3 unexpectedly fires on mori's workspace, stop: that is a
  flagship regression, not a mori bug — downgrade the code to warning-only, record in the
  Decision Log, and re-run the simulation.


## Interfaces and Dependencies

- **keiki 0.9.0.0 / keiki-codec-json 0.9.0.0** (Hackage candidates → published in M7): all
  keiro packages already bound `>=0.9 && <0.10`; no bound changes in this plan.
- **`keiro-dsl/src/Keiro/Dsl/Validate.hs`**: `DiagnosticCode` gains
  `DecodeBodyPostureUnsupported`, `DispatchOnAppendedUnsupported`, `TimerNotMineUnsupported`,
  `IntakeBindHeaderUnknown`; loses `EmitDeriveHoleUnrealized`; `WqFieldOptionalUnsupported`
  changes meaning (explicit-optional refusal) or is removed — final shape recorded in the
  Decision Log during M3. All remain `Ord`/`Enum`/`Bounded`-derivable; serialization stays
  Show-name-based so reordering is wire-safe.
- **`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs`**: `WorkspaceScaffoldReport` gains
  `wsrInertNodes :: [InertNodeReport]` (same type the single-spec `reportInertNodes` uses).
- **`keiro-dsl/app/Main.hs`**: deny-policy scan signature widens to accept coverage
  findings; report writer creates parent dirs; workspace check writes reports on refusal.
- **`keiro-dsl/tools/corpus-regen/src/CorpusPlan.hs`**: plan derivation additionally parses
  `keiro-dsl/keiro-dsl.cabal` test-suite stanzas; `checkCabalInventory` compares both ways.
- **`keiro/src/Keiro/Inbox/Kafka.hs`**: the fixed envelope-header set becomes the reference
  for `IntakeBindHeaderUnknown` — export the list (new exposed value) rather than duplicating
  strings in keiro-dsl, since keiro-dsl already depends on keiro in conformance suites;
  if a src-level dependency is undesirable, mirror the list with a cross-package equality
  test. Decide during M3 and record.
- **ADRs**: 0004 inventory re-amended (M3); 0020 amended (M1); 0021 gains alias-content
  validation rules and the case-convention exemption (M4); 0022 unchanged.
