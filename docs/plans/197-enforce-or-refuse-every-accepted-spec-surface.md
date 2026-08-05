---
id: 197
slug: enforce-or-refuse-every-accepted-spec-surface
title: "Enforce or refuse every accepted spec surface"
kind: exec-plan
created_at: 2026-08-05T04:54:27Z
intention: "intention_01kz84b5jre3187dmmyjmd02fc"
master_plan: "docs/masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md"
---

# Enforce or refuse every accepted spec surface

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, nothing a spec author writes in a `.keiro` file is silently ignored: every
construct the grammar accepts is enforced by a validator, diagnosed with a located warning, or
explicitly documented as descriptive-only — and the scaffold report says so out loud when a node
produces no generated modules. Today an author can write `correlate input.ghost via fn` in a
process, `dispatch Hospital@input.nonexistent`, a workqueue payload field typed `numeric`, a
`retry 99999999999999999999s` window, or `resolve stable from readmodel r row { ghostColumn }`,
and `keiro-dsl check` says nothing while the generated service quietly does something other than
what the spec claims (the `numeric` field becomes `Text`; the oversized window becomes a wrapped
arbitrary delay; the phantom column flows into `resolved.*` bindings unchecked). The user docs
compound this by advertising several of these surfaces as enforced or generated.

The 2026-08-04 pre-adoption audit (MasterPlan
[docs/masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md](../masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md),
this is EP-197, Phase 2) inventoried every such surface. This plan ratifies one disposition per
surface — enforce (error under the unreleased language-4 strict closure set), warn
(CI-escalatable), or document-as-descriptive-only — and then implements all of them. Observable
outcome: for each newly enforced surface there is a spec snippet that passed `check` before this
plan and now fails (or warns) with a named stable diagnostic code and a source line; for each
descriptive-only surface the user documentation and the ADR 0004 inventory state the limitation
in plain words; and `keiro-dsl scaffold` reports which declared nodes contributed no modules.
Every existing committed fixture and conformance suite passes byte-unchanged.


## Progress

- [x] (2026-08-04) Re-verified every audit anchor against the working tree (file and line
  evidence recorded in Context and Orientation), captured the corrected oversized-window failure
  mode (`readMaybe @Int` wraps rather than fails; see Surprises & Discoveries), confirmed no
  committed workqueue fixture uses a payload type outside `text`/`int`/`bool`, and authored this
  plan with the disposition inventory seeded in the Decision Log.
- [x] (2026-08-05) Milestone 1: ratified the inventory in code — added the four unconditional warnings
  (`IntakeBindFlagUnenforced`, `EmitDeriveHoleUnrealized`, `WqFieldOptionalUnsupported`,
  `RmInlineSubscriptionIgnored`), the scaffold-report no-modules note for emit/pgmq
  dispatch/operation nodes, and the documentation truth pass over
  `docs/user/typed-spec-toolchain.md`. The focused suite passes 588 examples with zero failures;
  a real scaffold report names `emit reservationResponse` as contributing no modules.
- [ ] Milestone 2: reference-resolution parity between process and router nodes —
  `ProcessKeyFieldUnknown`, `ProcessDispatchKeyUnresolved`, `ProcessBindingUnscoped`, and the
  revived `RouterReadModelUnverified` resolve-row column check, all gated on
  `enforcesSpecSurfaceClosures`.
- [ ] Milestone 3: closed vocabularies and bounded values (`WqPayloadTypeUnknown`,
  `WindowOutOfRange`, the small-surface cluster), dead-diagnostic cleanup including the new
  `RouterBenignInversion` code, the ADR 0004 inventory amendment, changelogs, and full closure
  gates.


## Surprises & Discoveries

- Observation (pre-plan verification): oversized windows do not lower to zero as the audit first
  recorded — they lower to a silently wrapped `Int`. `windowSeconds` in
  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (lines 6361-6372) uses `readMaybe` at `Int`, and GHC's
  `Read Int` wraps out-of-range decimals instead of failing, so the `either (const "0")` arm in
  `windowText` (line 6375) is unreachable for parser-produced windows. The wrong output is a
  wrapped delay, which can be any value including small or negative.
  Evidence:

  ```console
  $ ghc -e 'Text.Read.readMaybe "99999999999999999999" :: Maybe Int'
  Just 7766279631452241919
  ```

- Observation: the generated contract payload parser is lenient by construction. `parse<C>Payload`
  in `emitContractGen` (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` around line 2833) uses Aeson's
  `withObject` and `o .:`, which ignore unknown object keys. So an intake's declared
  `body lenient` happens to describe reality while `body strict` claims a rejection posture
  nothing implements — and neither word reaches any generated or runtime code.

- Observation: the runtime inbox cannot consume a decode posture today.
  `runInboxTransactionWith` in `keiro/src/Keiro/Inbox.hs` (line 105) receives an
  already-decoded `IntegrationEvent`; body decoding happens in hand-owned consumer wiring
  (hole-kind 8, delegated to deployment) before the runtime is involved. Lowering
  `decBodyStrict` into a generated constant would create a value with no forced consumer and
  would change generated bytes for every existing intake. This drove the B disposition
  (descriptive-only) recorded in the Decision Log.

- Observation: the `messageId derive … hole` and `idempotencyKey derive … hole` lines are
  mandatory emit syntax (`pEmit` in `keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs`, lines
  174-177), so the `EmitDeriveHoleUnrealized` warning necessarily fires once per emit node. That
  is accepted: the emit node genuinely generates nothing, and the warning is the staged,
  CI-escalatable honesty signal until a future feature plan adds generation.

- Observation: every committed workqueue fixture already types payload fields with `text`,
  `int`, or `bool` and marks them `required` (verified by grep over `keiro-dsl/test/fixtures/`),
  so closing the payload type vocabulary and warning on omitted `required` costs zero corpus
  churn and changes no generated bytes.

- Observation: the router-side twins of the Milestone 2 rules (`RouterKeyFieldUnknown`,
  `RouterBindingUnscoped`, router command/field checks) are ungated released errors from EP-108.
  The new process twins must nevertheless ride the strict closure gate per the MasterPlan 29
  policy, so process and router acceptance are asymmetric under languages 1-3 and symmetric under
  language 4. This asymmetry is deliberate and documented.


## Decision Log

- Decision: Adopt MasterPlan 29's enforcement policy verbatim as this plan's ratification rule.
  A surface becomes an Error only when the defect is internally decidable from one checked graph
  AND produces wrong or non-compiling output, and every such error is gated on the language-4
  `StrictSpecSurfaceValidation` closure capability through the existing
  `enforcesSpecSurfaceClosures` helper (`keiro-dsl/src/Keiro/Dsl/Validate.hs`, lines 435-437),
  exactly as plan 180's Tier B rules were. A merely inert surface gets an unconditional Warning
  (CI-escalatable once EP-193's `--deny-warnings` lands). A surface that is deliberately
  informational is named descriptive-only in the user docs and the ADR 0004 inventory.
  Rationale: the Mori `family` regression proved that hard-refusing previously valid specs
  without a staged path breaks committed workspaces; released languages 1-3 keep their exact
  acceptance (ADR 0016 freeze), and CI can opt into strictness via EP-193's `--min-language` and
  warning escalation.
  Date: 2026-08-04

- Decision (surface A — intake `bind` rows): Warn, do not enforce. Bind field names already
  resolve under language 4 (`IntakeBindUnresolved`, Validate.hs lines 1963-1968), but the rows
  themselves feed no generator, and the `required` / `cross-check body` flags promise runtime
  behavior that nothing implements. New unconditional warning `IntakeBindFlagUnenforced` on each
  bind row carrying either flag; docs state that bind rows are a checked wire-mapping description
  that generated code does not consume. Full envelope binding is feature work, out of scope.
  Date: 2026-08-04

- Decision (surface B — `decode { body strict|lenient }`): Document as descriptive-only; no
  warning and no lowering. The posture is mandatory intake syntax, so a warning would fire on
  every intake in every spec, and the investigation recorded in Surprises & Discoveries shows no
  consumable lowering point exists without keiro-core or adapter changes, while adding an
  unconsumed generated constant would break byte-stability for all existing intakes. The already
  enforced parts stay enforced: the envelope policy vocabulary (`IntakeEnvelopePolicyUnknown`)
  and the schema-version equality (`IntakeDecodeSchemaVersionMismatch`), plus diff's
  `DecodePostureChanged` classification. Docs must stop implying the body word is enforced. A
  future per-intake strict payload parser is possible feature-IR material
  (`docs/improvement-requests/` conventions) but no IR is created by this plan.
  Date: 2026-08-04

- Decision (surface C — `emit`, pgmq `dispatch`, `operation` scaffold nothing): Honesty, not
  generation. Full code generation for these nodes is a feature plan, out of scope. This plan:
  (i) makes the scaffold report explicitly list declared nodes that produced no modules; (ii)
  rewrites the docs to describe what the nodes DO provide (validation and diff classification)
  and deletes the false claim that `derive ["prefix"] hole` "creates a typed hand-owned
  derivation point"; (iii) adds unconditional warning `EmitDeriveHoleUnrealized` on the emit
  derive lines naming the limitation; (iv) notes in docs that a future feature plan may add
  generation, without creating the improvement request here.
  Date: 2026-08-04

- Decision (surfaces D, E, F, H — process/router resolution parity): Enforce under the strict
  closure gate. Port the router's released checks to processes with new append-only codes:
  `ProcessKeyFieldUnknown` (correlate field must be a declared input field, twin of
  `RouterKeyFieldUnknown`), `ProcessDispatchKeyUnresolved` (a `dispatch T@<key>` / `fire dispatch
  T@<key>` key must be `correlationId` or `input.<declared field>`), and `ProcessBindingUnscoped`
  (binding values must be quoted literals, `input.<declared field>`, or bare declared input
  names, mirroring `RouterBindingUnscoped`; the timer-fire scope additionally admits declared
  timer payload field names — confirm the exact admitted forms against every committed process
  fixture before freezing the set, and record the final scope vocabulary here). For H, revive
  the dead constructor `RouterReadModelUnverified` (declared Validate.hs line 202, never
  constructed since ExecPlan 108) as the strict-gated error for a `resolve … row { … }` column
  that is not a declared column of the resolved read model; downstream `resolved.<f>` binding
  checks then compare against verified columns. Wrongness argument: an unresolvable correlate or
  dispatch key or phantom resolve column yields a service that cannot route as declared.
  Date: 2026-08-04

- Decision (surface G — workqueue payload field types): Enforce under the strict closure gate
  with new code `WqPayloadTypeUnknown`. The generated record's `hsType` maps everything outside
  `bool`/`int` to `Text` (Scaffold.hs lines 3228-3230), so a declared `numeric` silently becomes
  `Text` — wrong output. The closed vocabulary is exactly `text`, `int`, `bool` (what `hsType`
  can lower). Fixture evidence shows no committed spec uses anything else, so no generated byte
  changes and no corpus migration.
  Date: 2026-08-04

- Decision (surface J — oversized windows): Enforce under the strict closure gate with new code
  `WindowOutOfRange`, implemented as a validation rule over every declared window (intake and
  workqueue disposition `retry` windows, publisher backoff window and max, workqueue
  `delay`, process `fireAt` window) requiring the digits parsed at `Integer`, multiplied by the
  unit factor (1/60/3600), to fit in `Int` — the same overflow discipline `boundedDecimal` /
  `checkedDecimal` already applies to bare decimals (`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`
  lines 170-187). The parser (`pWindow`) is left unchanged so released-language acceptance is
  untouched; the check lives in `Validate.hs`, not the parser, precisely so it can ride the gate.
  Date: 2026-08-04

- Decision (surface I — small-surface cluster, one disposition per item; no syntax is stripped
  because grammar removal is a breaking change): (1) workqueue field `required` flag — the
  generated Aeson parser always uses `.:` (Scaffold.hs line 3234), so an un-flagged field is
  still decode-required; unconditional warning `WqFieldOptionalUnsupported` on fields lacking
  `required`, docs state all payload fields are required at decode. (2) timer
  `decode unknown-status => <name>` — mandatory syntax with no consumer beyond pretty-printing;
  descriptive-only in docs, no warning. (3) timer `dead-letter "<category>"` — lowered only into
  a hole comment (Scaffold.hs line 3775); strict-gated error `TimerDeadLetterCategoryInvalid`
  applying the existing category identity rule (`runtimeIdentityError False`), docs note the
  category otherwise remains operator guidance. (4) `timer id uuidv5 "p:" <> <ident>` — the
  identifier is parsed and discarded (`pIdExpr`, Parser/Coordination.hs line 252) and always
  means `correlationId`; store the identifier in the AST and add strict-gated error
  `TimerIdFieldNotCorrelation` when it is not literally `correlationId`. (5) aggregate
  `projection … key=<name>` — name-shape checked only (Validate.hs line 1165); strict-gated
  error `AggProjectionKeyUnresolved` resolving the key against the union of the aggregate's
  register names and command/event field names (all committed fixtures use `reservationId`,
  which resolves). (6) pgmq dispatch `source … key=` and `fanout body=` — resolve both against
  the source read model's declared columns, reusing existing code
  `DispatchReadModelFieldUnknown` under the gate (same failure class as the already-checked
  dedup-side field, Validate.hs lines 1932-1938); for `dedup key=`, first inventory the
  committed dispatch fixtures — if it names a source read-model column everywhere, close it the
  same way, otherwise document it descriptive-only and record the choice here. (7) publisher
  `outboxId stable from <field>` — diff-tracked only (Diff.hs line 2150); strict-gated error
  `PublisherOutboxFieldUnresolved` with vocabulary `messageId`, `idempotencyKey`, or a field of
  the emit's mapped contract events; verify committed fixtures (which use `messageId`) before
  freezing, downgrade to warning and record here if any committed spec falls outside. (8)
  readmodel `subscription="…"` beside `feed=inline` — the override is meaningless for an inline
  feed; unconditional warning `RmInlineSubscriptionIgnored`. (9) read-model subscription
  override and scope category strings — they become runtime identities
  (`subscriptionNameFor`, `keiro-dsl/src/Keiro/Dsl/ReadModelShape.hs` line 55) yet are
  unvalidated; strict-gated errors reusing the plan-180 code `RuntimeIdentityInvalid` and its
  `stableIdentityError` helper.
  Date: 2026-08-04

- Decision (surface K — dead diagnostic codes): Remove the never-constructed constructors
  `IdentHaskellKeyword`, `IdentNotConstructorSafe` (Validate.hs lines 174-175),
  `DuplicateUpcasterSource` (declared line 67; its rule is a deliberate no-op, lines 2819-2820),
  and `MappedGuardUnsupported` (declared line 245; `mappedGuardRules` stub returns `[]`, lines
  1075-1076), together with their dead rule stubs, keeping the explanatory comments where they
  document real invariants. `RouterReadModelUnverified` is implemented rather than removed (see
  D-H decision). The router's duplicate-AckOk notice (Validate.hs lines 2420-2424) stops
  borrowing the process code: append new code `RouterBenignInversion` and emit it at the router
  site, leaving `ProcessBenignInversion` untouched for processes. Before deleting
  `IdentHaskellKeyword`/`IdentNotConstructorSafe`, confirm EP-192 (which owns the reserved-word
  policy) has not started constructing them; if it has, keep them and record the reversal here.
  Rationale: exported constructors that no code path can emit misrepresent the diagnostic
  contract; plan 180 Milestone 5 set the precedent by deleting dead grammar. The removals ship
  in the same unreleased 0.9.0.0 window as language 4 and are called out in both changelogs.
  Date: 2026-08-04

- Decision: New errors emit nothing (not warnings) under released languages 1-3.
  Rationale: ADR 0016 freezes released acceptance and released diagnostic output; plan 180's
  Tier B rules set the exact precedent, and EP-193's `--min-language` floor gives CI a way to
  require the strict contract without this plan changing what released languages print.
  Date: 2026-08-04


## Outcomes & Retrospective

Milestone 1 is complete. Four accepted-but-inert declarations now produce ordinary warnings,
single-file scaffold reports name validated and diff-classified nodes that contributed no
modules, and the user guide distinguishes generated or enforced behavior from descriptive-only
notation. The focused suite grew from the captured 582-example baseline to 588 examples and
passes with zero failures. Reference-resolution and strict-closure work remains in Milestones 2
and 3. At completion, record the final scope vocabulary chosen for
`ProcessBindingUnscoped`, the `dedup key=` and `outboxId` disposition confirmations, exact test
counts, evidence that no committed fixture changed bytes, and the ADR distillation.


## Context and Orientation

A `.keiro` file declares an event-sourced service: aggregates (state machines with commands,
events, and guarded transitions), integration contracts (shared Kafka message schemas), intakes
(Kafka consumers), emits and publishers (outbox mappings and their delivery policy), workqueues
and pgmq dispatches (PostgreSQL job queues and fan-out), read models (projected SQL tables),
workflows, processes (process managers with timers), routers (stateless content-based
dispatch), and operations (named entry points). The parser under
`keiro-dsl/src/Keiro/Dsl/Parser/` builds the AST in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`;
`validateCheckedSpec` in `keiro-dsl/src/Keiro/Dsl/Validate.hs` produces `Diagnostic` values
carrying a stable machine-readable `DiagnosticCode`, a `Severity` (`Error` or `Warning`), a
line, and a message; `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` emits generated Haskell;
`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` plans writes and renders the scaffold report;
`keiro-dsl/src/Keiro/Dsl/Diff.hs` classifies cross-spec changes. The CLI (`keiro-dsl/app/Main.hs`)
prints every diagnostic and exits nonzero only when an `Error` is present, so warnings never
change acceptance by themselves.

Two terms of art. An "inert surface" is a construct the parser accepts and stores that no
validator, generator, or diff rule meaningfully consumes: the author believes they declared
behavior, and nothing enforces it. "Descriptive-only" is the deliberate, documented version of
the same thing: the construct is honest prose in the spec (documentation for humans and holes),
and the docs and ADR inventory say so explicitly.

The "strict closure set" is the language-4 gating mechanism from plan 180
([docs/plans/180-close-accepted-but-unenforced-spec-surfaces-before-language-4-ships.md](180-close-accepted-but-unenforced-spec-surfaces-before-language-4-ships.md)):
`enforcesSpecSurfaceClosures :: EffectiveLanguageContract -> Bool` (Validate.hs lines 435-437)
returns true exactly when the effective runtime profile carries the
`StrictSpecSurfaceValidation` capability (registered in
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`), which only unreleased language 4 selects. A rule
guarded on it fires for language-4 specs and is invisible to released languages 1-3. Language 4
has still not shipped (0.8.0.0 released versions 1-3), so this is the same free-tightening
window plan 180 used.

The verified inventory of surfaces, each with its ratified disposition (the Decision Log holds
the reasoning):

Surface A — intake `bind` rows are inert. `BindRow` with `brRequired`/`brCrossCheck` flags
(Grammar.hs lines 852-859; parsed in `keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs` lines
109-116). The bound field NAME resolves under language 4 (Validate.hs lines 1963-1968), but no
consumer exists in Scaffold (the generated `Inbox.hs`, emitted by `emitIntakeGen` at Scaffold.hs
lines 2986-3064, lowers dedupe policy, persistence, and dispositions — no envelope binding),
none in Diff beyond whole-record equality, none in the harness. The docs showcase the flags
(`docs/user/typed-spec-toolchain.md` lines 892-897). Disposition: warn on flags + docs truth.

Surface B — `decode { body strict|lenient }` is never enforced or lowered. `decBodyStrict`
(Grammar.hs lines 880-886) reaches only the pretty-printer and diff's whole-record
`DecodePostureChanged` advisory (Diff.hs lines 2062-2069). The envelope policy word and the
schema version ARE checked (Validate.hs around lines 2122-2124 and below). Disposition:
descriptive-only + docs truth (see the Decision Log investigation).

Surface C — `emit`, pgmq `dispatch`, and `operation` nodes scaffold nothing.
`scaffoldServiceModulesWithGoldens` returns `[]` for all three (ScaffoldRun.hs lines 195-197);
`emName`, `emMap`, `emMessageId`, `dsPrefix` appear nowhere in Scaffold.hs. All three are
genuinely validated (emit: catch-all/map/contract/topic rules around Validate.hs line 2002;
dispatch: `validatePgmqDispatch` line 1909; operation: `validateOperation` via line 1481) and
diff-classified. But `docs/user/typed-spec-toolchain.md` line 973 claims `derive ["prefix"]
hole` "creates a typed hand-owned derivation point" — nothing is created — and the scaffold
report is silent about the missing modules. Disposition: report honesty + docs truth + derive
warning; generation is out of scope.

Surface D — process `correlate input.<field> via <fn>` is unchecked while the router twin is
checked (`RouterKeyFieldUnknown`, Validate.hs lines 2369-2373). `validateProcess` (lines
2173-2309) never reads `procCorrelate`. Disposition: strict-gated error `ProcessKeyFieldUnknown`.

Surface E — dispatch key expressions are never resolved. `dispKey` (Grammar.hs lines 668-676)
and `fireKey` (lines 722-730) accept any dotted token (`dottedRef`,
`keiro-dsl/src/Keiro/Dsl/Parser/Coordination.hs` lines 193 and 269). Disposition: strict-gated
error `ProcessDispatchKeyUnresolved`.

Surface F — process field-binding VALUES are unscoped. The router checks values against input,
resolve-row, and quoted-literal scopes (`RouterBindingUnscoped`, Validate.hs lines 2375-2389);
the process checks only bound NAMES against the target command (lines 2261-2273), and Scaffold
lowers only quoted literals into the deterministic payload (`payloadExpr`, Scaffold.hs lines
3793-3800). Disposition: strict-gated error `ProcessBindingUnscoped`.

Surface G — workqueue payload field types are an open vocabulary. The parser accepts any
identifier (`pWqField`, `keiro-dsl/src/Keiro/Dsl/Parser/Queue.hs` lines 91-97); only the
group-key `raw`-requires-`text` coupling is checked (Validate.hs lines 1882-1886); `hsType`
maps everything except `bool`/`int` to `Text` (Scaffold.hs lines 3228-3230). Disposition:
strict-gated error `WqPayloadTypeUnknown` closing the vocabulary to `text`/`int`/`bool`.

Surface H — router `resolve … row { … }` columns are never checked against the read model, and
the diagnostic code for it is dead: `RouterReadModelUnverified` is declared (Validate.hs line
202) and never constructed; only read-model EXISTENCE is checked (lines 2405-2411), and the
`resolved.<f>` binding scope (line 2387) trusts the unverified `rvRow`. Disposition:
strict-gated error reviving `RouterReadModelUnverified`.

Surface I — the small-surface cluster, per-item dispositions in the Decision Log: the inert
workqueue `required` flag (generated parser always `.:`, Scaffold.hs line 3234); timer `decode
unknown-status => <name>` with no consumer (`tmDecodeUnknown` reaches only the pretty-printer;
parsed at Parser/Coordination.hs lines 228-229); timer `dead-letter "<category>"` lowered only
into a comment (Scaffold.hs line 3775) with the category never validated; `timer id uuidv5
"p:" <> <ident>` where the identifier is parsed and discarded (Parser/Coordination.hs line 252);
aggregate projection `key=<name>` never resolved (name-shape only, Validate.hs line 1165); pgmq
dispatch `source key=` / `fanout body=` / `dedup key=` accepted unresolved (`pdSourceKey`,
`pdFanoutBody`, `pdDedupKey` in Grammar.hs lines 1027-1040 have no Validate consumer, though the
dedup-side read-model field IS checked at lines 1932-1938); publisher `outboxId stable from
<field>` unresolved (`pubOutboxField` is diff-only, Diff.hs line 2150); readmodel
`subscription="…"` accepted beside `feed=inline` and ignored (optional in
`keiro-dsl/src/Keiro/Dsl/Parser/ReadModel.hs` line 32); and scope/subscription identity strings
unvalidated before becoming runtime identities (`subscriptionNameFor`, ReadModelShape.hs line 55).

Surface J — oversized windows lower to a silently wrapped delay. `pWindow` accepts unbounded
digits (`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs` lines 383-388); `windowSeconds`/`windowText`
(Scaffold.hs lines 6361-6375) feed `RetryDelay` and backoff constants at Scaffold.hs lines
3066, 3113-3118, 3312, and 3346. The repository already has the `boundedDecimal` overflow
discipline for exactly this class. Disposition: strict-gated error `WindowOutOfRange`.

Surface K — dead diagnostic codes: `IdentHaskellKeyword`, `IdentNotConstructorSafe`,
`DuplicateUpcasterSource`, `MappedGuardUnsupported` (never constructed; see Decision Log for
removal), `RouterReadModelUnverified` (implement), and the router's borrowed
`ProcessBenignInversion` at Validate.hs lines 2420-2424 (append `RouterBenignInversion`).

Relevant ADRs, read for this plan.
[ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) requires
every internally decidable failure to be rejected at the earliest sound boundary (normally
`check`), keeps `DiagnosticCode` append-only, states "the inventory is amended when a later
child plan changes a gate's ownership", and already carries the row acknowledging that "Emit
source/key/discriminant names remain documented as descriptive-only because no typed source
namespace exists" — this plan amends that row and adds the new gates.
[ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
freezes released-language meaning, which is why every new error rides the unreleased strict
closure gate. Plan 180 (path above) is the direct precedent for the gating pattern, the fixture
conventions, and the Decision Log entry that first named emit words descriptive-only. EP-193
([docs/plans/193-surface-the-effective-language-contract-and-enforce-warnings-in-ci.md](193-surface-the-effective-language-contract-and-enforce-warnings-in-ci.md),
soft dependency) owns warning escalation and the JSON check report; this plan's diagnostics go
through the existing `Validate.hs` pipeline and appear in that report without schema changes,
and this plan must not invent parallel rendering. EP-192 owns field identity; no rule here
touches field naming, so the only coordination is Validate.hs merge order (whoever merges later
rebases their rule list; nobody reorders existing rules).


## Plan of Work

### Milestone 1: Warnings, scaffold-report honesty, and the documentation truth pass

Scope: everything whose disposition is "warn" or "document", plus the report change. At the end
of this milestone, a spec using an inert flag prints a located warning naming the limitation,
`keiro-dsl scaffold` states which nodes produced no modules, and the user docs no longer
over-promise anywhere. No acceptance changes; no generated file changes.

In `keiro-dsl/src/Keiro/Dsl/Validate.hs`, append (never reorder) four `DiagnosticCode`
constructors: `IntakeBindFlagUnenforced`, `EmitDeriveHoleUnrealized`,
`WqFieldOptionalUnsupported`, `RmInlineSubscriptionIgnored`. Add unconditional Warning rules:
in the intake rules, one warning per `BindRow` whose `brRequired` or `brCrossCheck` is true,
message naming the flag and stating that generated code does not consume envelope bindings; in
the emit rules (`validateEmit` area, near line 2002), one warning per emit node at `emLoc`
stating that `derive … hole` names a hand-owned responsibility but generates no module or typed
signature; in the workqueue rules, one warning per payload field with `wqfRequired == False`
stating the generated decoder treats every field as required; in the read-model rules, one
warning when `rmSubscription` is `Just _` while `rmFeed` is `RmInline`, stating the override is
ignored for inline feeds. To find each rule's home, follow how the existing warnings there are
built (for example `WqUnloggedDurability` at Validate.hs lines 1893-1901).

In `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`, extend `ScaffoldReport` (line 152) with an
additive field `reportInertNodes :: ![(Text, Text)]` — pairs of node kind and node name —
populated in the report-construction path from the checked service's `NEmit`, `NPgmqDispatch`,
and `NOperation` nodes, and render it in `renderScaffoldReport` (line 965) after the module
lines, for example: `no-modules: emit reservationResponse, dispatch capacityFanout, operation
ConfirmReservation (validated and diff-classified; no generated modules)`. Update every test
that constructs or matches `ScaffoldReport`.

Documentation truth pass over `docs/user/typed-spec-toolchain.md`. Search the file for each
construct (`bind `, `cross-check`, `body strict`, `lenient`, `derive`, `unknown-status`,
`dead-letter`, `uuidv5`, `key=`, `outboxId`, `subscription`, `required`, `retry`, and the
workqueue payload type list) and fix every over-promise: line 973's "creates a typed hand-owned
derivation point" becomes an honest statement that the derive lines document a hand-owned
responsibility and generate nothing; lines 940-941 stop implying `body strict|lenient` is
enforced and state which decode facts ARE checked (envelope policy word, schema-version
equality) and that posture changes are diff-classified; the bind section states the flags are
unenforced; the workqueue section documents the closed `text`/`int`/`bool` vocabulary and that
every field is decode-required; the emit/publisher/dispatch/operation sections say plainly that
these nodes produce no generated modules today and enumerate what they do provide. Where a
Milestone 2 or 3 rule will change behavior, write the documentation for the end state in this
pass and note the language-4 gate.

Add ordinary warning tests to `keiro-dsl/test/Main.hs` using the existing fixture conventions
(`diagnosticCodesOf` returning codes for `shouldContain`): one fixture per new warning code, plus
an assertion that a clean fixture (for example `test/fixtures/reservation.keiro`) emits none of
them. Acceptance for the milestone: `nix develop -c cabal test keiro-dsl-test
--test-show-details=direct` passes with the new examples, and a scaffold of any fixture
containing an emit node prints the `no-modules:` line.

### Milestone 2: Reference-resolution parity between process and router nodes

Scope: surfaces D, E, F, H. At the end, a language-4 process spec with an unresolvable
correlate field, dispatch key, or binding value fails `check` with a located error, and a
language-4 router spec naming a phantom resolve-row column fails with
`RouterReadModelUnverified`; the identical language-3 specs still pass.

In `Validate.hs`, append `ProcessKeyFieldUnknown`, `ProcessDispatchKeyUnresolved`, and
`ProcessBindingUnscoped`. Thread the `EffectiveLanguageContract` into `validateProcess` and
`validateRouter` the same way `intakeCoupling` receives it (see `validateNode` dispatch and the
plan-180 pattern), and guard every new rule with `enforcesSpecSurfaceClosures languageContract`.

In `validateProcess` (lines 2173-2309): add a correlate rule mirroring the router's `keyField`
(lines 2369-2373) — `corrField (procCorrelate p)` must be an element of `inputFields`, error
`ProcessKeyFieldUnknown` at the process line. Add a key-resolution rule over `dispKey` of every
`hDispatch` entry and `fireKey` of the timer fire: a key is valid when it is exactly
`correlationId` or has the form `input.<field>` with `<field>` declared on the process input;
anything else is `ProcessDispatchKeyUnresolved` at the dispatch/timer line. Add a value-scoping
rule over `advFields`, `dispFields`, and `fireFields` bindings mirroring the router's
`bindingScope` (lines 2375-2389): a binding with no value requires its NAME be a declared input
field; a valued binding requires a quoted literal, `input.<declared field>`, or a bare declared
input name; for the timer fire, additionally admit declared timer payload field names. Before
freezing that scope set, run the rule over every committed process fixture
(`test/fixtures/*.keiro` with `process` nodes and the conformance workspaces) and widen only to
forms those fixtures actually use, recording the final vocabulary in the Decision Log.

In `validateRouter`, extend `readModelReference` (lines 2405-2411): when the resolve source
names a declared read model, emit `RouterReadModelUnverified` (Error, strict-gated) at the
resolve line for every `rvRow` column not present in the model's `rmColumns` by `rmcName`. Note
`rvRow` holds DSL names while `rmcName` holds column names — match on the same identity the
`resolved.<f>` binding scope uses so the two rules agree; state the chosen identity in the rule's
comment.

Tests: for each new code, a language-4 fixture failing with exactly that code and a
language-3 twin that passes, following plan 180's paired-fixture convention. Also a positive
language-4 process fixture whose correlate, keys, and bindings all resolve, proving no false
positives. Acceptance: the focused suite passes; every pre-existing fixture is untouched.

### Milestone 3: Closed vocabularies, bounded values, cleanup, ADR amendment, and closure

Scope: surfaces G, J, the checkable half of I, the K cleanup, documentation/ADR/changelog
publication, and the full closure gates.

In `Validate.hs`, append `WqPayloadTypeUnknown`, `WindowOutOfRange`,
`TimerDeadLetterCategoryInvalid`, `TimerIdFieldNotCorrelation`, `AggProjectionKeyUnresolved`,
`PublisherOutboxFieldUnresolved`, and `RouterBenignInversion`, all strict-gated except
`RouterBenignInversion` (which is the unconditional warning replacing the router's borrowed
code at lines 2420-2424; the message text may stay). Implement, per the Decision Log
dispositions: the `text`/`int`/`bool` workqueue payload vocabulary; the window bound (factor the
digits-times-unit-fits-in-`Int` computation into one helper beside the validator, apply it to
intake/workqueue `retry` windows, publisher backoff window and max, workqueue delay, and the
process `fireAt` window — enumerate the exact `IRetry`/`BackoffSpec`/`wqDelay`/`faWindow`
sites); the timer dead-letter category identity check via `runtimeIdentityError False`; the
stored-and-checked timer id identifier (add a field such as `ideField :: !Name` to `IdExpr` in
Grammar.hs and keep `pIdExpr` accepting the same syntax — an AST field addition changes no
acceptance — then require it be `correlationId`); the projection-key resolution against
registers plus command/event field names; the pgmq `source key=`/`fanout body=` resolution
against source read-model columns reusing `DispatchReadModelFieldUnknown`, with the `dedup key=`
fixture inventory deciding its treatment; the publisher `outboxId` vocabulary; and the
read-model subscription/scope identity checks reusing `RuntimeIdentityInvalid` and
`stableIdentityError`.

Cleanup: delete `IdentHaskellKeyword`, `IdentNotConstructorSafe`, `DuplicateUpcasterSource`,
and `MappedGuardUnsupported` constructors plus the `duplicateUpcasterSourceRule` and
`mappedGuardRules` stubs (preserving their explanatory comments at the surviving sites), after
confirming with a repository search that nothing constructs or matches them (the only current
test reference is a `shouldNotContain [DuplicateUpcasterSource]` at test/Main.hs line 2818,
which is updated alongside) and that EP-192 has not claimed the two Ident codes.

Publication: amend ADR 0004's landed inventory — update the existing emit descriptive-only row
to name the full descriptive-only set (emit source/key/discriminant, emit derive holes, intake
bind rows and flags, decode body posture, timer unknown-status arm) and add rows for the new
strict-gated gates (process/router resolution parity with revived resolve-row verification,
closed workqueue payload vocabulary, bounded windows, runtime-identity coverage for read-model
subscription/scope) — then append a `docs/adr/log.md` entry via `okf log add`. Update
`CHANGELOG.md` and `keiro-dsl/CHANGELOG.md` describing the language-4 tightening, the new
warnings, the scaffold-report note, the router warning code change, and the removed dead
constructors. Re-run the Milestone 1 docs grep to catch anything the new rules changed.

Tests: paired language-4-fails/language-3-passes fixtures per new error code; a warning test
for `RouterBenignInversion`; a byte-stability assertion that regenerating the committed
conformance corpus produces no diff (the fixtures all use the closed vocabularies already).
Acceptance: the full closure command set below passes.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/keiro`.

Before editing, reproduce two representative accepted holes through the real CLI so the defect
evidence is pinned (stream scratch specs via `/dev/stdin` as plan 180 did):

```bash
nix develop -c cabal run keiro-dsl:exe:keiro-dsl -- check /dev/stdin
```

The pre-enforcement transcripts were captured after Milestone 1 and before either strict-gated
milestone. Replacing the hospital-surge correlate field with `ghost` still exited zero:

```console
$ sed 's/correlate input.hospitalId/correlate input.ghost/' keiro-dsl/test/fixtures/hospital-surge.keiro | nix develop -c cabal run -v0 keiro-dsl:exe:keiro-dsl -- check /dev/stdin
/dev/stdin:17: warning[ProcessBenignInversion]: dispatch to 'Hospital' maps on-duplicate => AckOk (a duplicate is treated as benign success)
/dev/stdin:25: warning[ProcessBenignInversion]: timer 'surgeFollowUp' maps on-reject => Fired (a CommandRejected is treated as benign success)
OK
```

Changing the non-group-key `hospitalId` queue payload row from `text` to `numeric` also exited
zero (changing the group key itself already trips the older `WqGroupKeyUnresolved` rule):

```console
$ sed '0,/hospitalId -> "hospital_id" text required/s//hospitalId -> "hospital_id" numeric required/' keiro-dsl/test/fixtures/reservation-work.keiro | nix develop -c cabal run -v0 keiro-dsl:exe:keiro-dsl -- check /dev/stdin
OK
```

After each milestone, run the focused suite:

```console
$ nix develop -c cabal test keiro-dsl-test --test-show-details=direct
...
0 failures
```

Update this plan with the exact example counts as they land (the suite passed 482 examples at
plan 180's close; the current baseline must be captured before Milestone 1).

To see the Milestone 1 scaffold-report note, scaffold a fixture with an emit node into a
disposable directory:

```console
$ proof_dir=$(mktemp -d)
$ nix develop -c cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation.keiro --out "$proof_dir"
...
no-modules: emit ... (validated and diff-classified; no generated modules)
```

(Use any committed fixture that declares an emit, pgmq dispatch, or operation node; verify the
choice with `rg -l "^emit |^dispatch |^operation " keiro-dsl/test/fixtures`. Remove only the
explicitly created disposable directory afterward.)

Full closure after Milestone 3:

```console
$ nix develop -c cabal test keiro-dsl
...
All ... test suites passed

$ nix develop -c cabal build all
...

$ scripts/check-extension-policy.sh
extension policy: ok

$ scripts/check-generated-name-policy.sh
generated Haskell naming policy: ok

$ okf log add docs/adr --kind Update -m "Amend the gate inventory with plan-197 enforcement, warning, and descriptive-only dispositions."
$ okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
...
validation succeeded

$ git diff --check
```

A blank `git diff --check` result is success.


## Validation and Acceptance

Acceptance is behavioral, per surface:

1. Under `language keiro-dsl 4`: a process whose `correlate` names an undeclared input field
   fails `check` with `ProcessKeyFieldUnknown`; a `dispatch T@input.ghost` or
   `fire dispatch T@ghost` fails with `ProcessDispatchKeyUnresolved`; a dispatch binding value
   outside the ratified scope set fails with `ProcessBindingUnscoped`; a router resolve row
   naming a column absent from the read model fails with `RouterReadModelUnverified`; a
   workqueue payload field typed `numeric` fails with `WqPayloadTypeUnknown`; a
   `retry 99999999999999999999s` fails with `WindowOutOfRange`; the timer, projection-key,
   pgmq-source, publisher-outboxId, and read-model-identity cases fail with their named codes.
   Every one of these specs, respelled at `language keiro-dsl 3`, still passes `check`.
2. Under every language version: a bind row with `required` or `cross-check body` warns
   `IntakeBindFlagUnenforced`; an emit node warns `EmitDeriveHoleUnrealized`; a workqueue field
   without `required` warns `WqFieldOptionalUnsupported`; `subscription=` beside `feed=inline`
   warns `RmInlineSubscriptionIgnored`; a router duplicate-AckOk disposition warns
   `RouterBenignInversion` (and no longer `ProcessBenignInversion`). Warnings never change the
   exit code.
3. `keiro-dsl scaffold` over a spec declaring emit, pgmq dispatch, or operation nodes prints
   the `no-modules:` report line naming each such node; a spec without them prints no such line.
4. `docs/user/typed-spec-toolchain.md` contains no claim that an unenforced surface is checked
   or generated: in particular the `derive … hole` "creates" sentence and the `body
   strict|lenient` framing are gone, replaced by explicit descriptive-only statements.
5. The four dead constructors no longer exist: a repository search for `IdentHaskellKeyword`,
   `IdentNotConstructorSafe`, `DuplicateUpcasterSource`, or `MappedGuardUnsupported` under
   `keiro-dsl/src` and `keiro-dsl/test` returns nothing.
6. Byte stability: every committed fixture and conformance suite passes unchanged; no generated
   file in the repository is modified by this plan; fold fingerprints, wire bytes, and snapshot
   discriminators are untouched (the existing normalized byte-equality and fold-baseline goldens
   prove it as part of the full suite).
7. `nix develop -c cabal test keiro-dsl`, `nix develop -c cabal build all`, both policy
   scripts, strict OKF ADR validation, and `git diff --check` all pass.


## Idempotence and Recovery

All edits are deterministic source changes; validators and tests can be rerun freely.
`DiagnosticCode` constructors are append-only — never reorder or rename released constructors,
and the four removals are of constructors proven never-emitted (the removal commit must contain
the proving search). If a strict-gated rule turns out to reject a committed fixture or Mori's
workspace shape, do not weaken it silently: either the fixture documents a real defect (fix the
fixture and record why) or the rule is wrongly scoped (downgrade it to the warning tier and
record the reversal in the Decision Log) — never hard-refuse a previously valid spec outside
the language-4 gate. The scaffold-report field is additive; reverting it is a single-field
removal. Scratch defect-evidence specs live outside the repository and are recreatable from the
transcripts recorded in Concrete Steps. If EP-192 or EP-194 merges into `Validate.hs` first,
rebase this plan's rule list onto theirs without reordering existing rules; diagnostic order is
part of the deterministic output contract.


## Interfaces and Dependencies

All work is inside `keiro-dsl` (canonical URI `mori://shinzui/keiro/packages/keiro-dsl`) plus
documentation; no new external dependency and no keiro-core, keiki, or Cabal-bound change. The
runtime facts consulted read-only during research were `keiro/src/Keiro/Inbox.hs`
(`runInboxTransactionWith` takes a decoded `IntegrationEvent`) and the generated contract
parser shape in `Scaffold.hs`.

`keiro-dsl/src/Keiro/Dsl/Validate.hs` appends exactly these `DiagnosticCode` constructors, in
one block at the end of the existing declaration: `IntakeBindFlagUnenforced`,
`EmitDeriveHoleUnrealized`, `WqFieldOptionalUnsupported`, `RmInlineSubscriptionIgnored`,
`ProcessKeyFieldUnknown`, `ProcessDispatchKeyUnresolved`, `ProcessBindingUnscoped`,
`WqPayloadTypeUnknown`, `WindowOutOfRange`, `TimerDeadLetterCategoryInvalid`,
`TimerIdFieldNotCorrelation`, `AggProjectionKeyUnresolved`, `PublisherOutboxFieldUnresolved`,
`RouterBenignInversion` — and removes `IdentHaskellKeyword`, `IdentNotConstructorSafe`,
`DuplicateUpcasterSource`, `MappedGuardUnsupported`. `RouterReadModelUnverified` gains its
first construction site. Strict-gated rules receive the `EffectiveLanguageContract` the same
way `intakeCoupling` does and consult:

```haskell
enforcesSpecSurfaceClosures :: EffectiveLanguageContract -> Bool
```

The window bound is one shared helper beside the validator (name at implementer's discretion),
with the effective shape:

```haskell
-- digits and unit from a parsed window such as "500s"; Left when the
-- unit-multiplied seconds cannot be represented as Int
windowSecondsBounded :: Text -> Either Text Int
```

`Scaffold.hs`'s `windowSeconds` may be reimplemented on top of it, but generated output for
every valid (in-range) window must remain byte-identical.

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` gains `ideField :: !Name` on `IdExpr` (populated by
`pIdExpr` instead of discarding the identifier); this is an internal AST addition with no
grammar acceptance change. `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` gains the additive
`reportInertNodes :: ![(Text, Text)]` field on `ScaffoldReport` and its rendering.

Coordination: EP-193 (soft dependency) owns warning escalation and the versioned JSON check
report; the new codes flow through the existing diagnostic pipeline and need no schema change.
EP-192 owns reserved-word policy; confirm the two Ident-code removals with its merged state.
EP-194 also edits `Validate.hs`; merge order is textual, later merger rebases. No plan in
MasterPlan 29 may change fold fingerprints, wire bytes, or snapshot discriminators, and this
plan changes none.


## Revision Notes

- 2026-08-05: Completed Milestone 1 with four warnings, additive single-file scaffold-report
  honesty, the user-guide truth pass, six focused regressions, the 582-example baseline, and a
  green 588-example focused suite. Captured the two accepted-hole CLI transcripts before strict
  enforcement begins.
