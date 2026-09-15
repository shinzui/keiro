---
id: 266
slug: classify-guard-unions-by-replay-body-and-validate-replay-only-remedies
title: "Classify guard unions by replay body and validate replay-only remedies"
kind: exec-plan
created_at: 2026-08-22T03:59:33Z
intention: "intention_01m0kst1x4ejdsnxmweqv8brne"
provenance:
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-15T20:57:23Z
      mode: "update"
      note: "Refresh API contracts and EP-265 handoff; correct full-union coverage, replay-impact integration, opaque ownership, and remedy validation boundaries."
---

# Classify guard unions by replay body and validate replay-only remedies


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current. Follow agents/skills/exec-plan/PLANS.md and ADR.md.
This is an implementation plan; the 2026-09-15 update changes documentation only.


## Purpose / Big Picture


After this plan, `keiro-dsl diff` compares the union of live guards for each replay body:
the ownership, ordered writes, ordered emitted events, and target of a transition within
one source-state/command family. It reports a changed or removed emitting body with one
`AggGuardTightened` advisory and a mechanically constructed replay-only transition,
but only after that transition survives insertion, rendering, parsing, and validation
under the candidate's effective language. Failure produces `AggGuardRemedyUnavailable`
with a reason and no paste-ready transition.

This follows [ExecPlan 265](265-make-aggregate-transition-family-diffs-idempotent-and-order-independent.md).
That prerequisite owns exact multiset cancellation and the shared family partition.
This plan uses its remainders to identify affected bodies, then compares the complete
old and new live guard sets for those bodies. Already-cancelled siblings can still cover
history and must participate in the unions. Existing replay-only coverage is looked up
in the full candidate aggregate, independently of cancellation.

The work remains structural: syntactically proved preservation suppresses an advisory;
an unproved generated guard change keeps its exact remedy even when its removed region
might be empty. No solver, satisfiability proof, dependency change, or fold-encoding
migration is included. The accepted and deferred scope is recorded in
`docs/improvement-requests/make-aggregate-guard-diffs-idempotent-and-semantically-exact.md`
(IR-33). Source validation is not a proof of runtime inversion or hand-written Hole
behavior; runtime conformance and targeted replay audits remain independent gates.


## Progress


- [x] (2026-09-15) Refresh against current record, checked-service, parser, renderer,
      validation, diff-report, and replay-impact APIs and the updated EP-265 contract.
- [ ] Confirm EP-265 implementation and acceptance are complete; inspect its actual private
      family types before extending them.
- [ ] Add deterministic body grouping over full family members, using exact remainders only
      to select affected bodies; share the syntactic preservation helper.
- [ ] Make diff and replay impact consume the same generated-body classification, preserving
      replay-only removal, no-emit snapshot, codec, and non-transition impact behavior.
- [ ] Implement exact whole-union twins, complete-candidate same-body coverage, and honest
      Hole-owned unknown cases.
- [ ] Thread checked services through the existing diff pass; validate all advertised remedies
      through the candidate effective language; append AggGuardRemedyUnavailable.
- [ ] Cover cancellation survivors, duplicates, splits/merges, removed families, stale and
      mismatched twins, Hole ownership, outcome clearing, and Languages 1–5.
- [ ] Run CLI, runtime, disposable Mori, package, formatting, and documentation gates;
      update durable ADRs and close IR-33's accepted scope.


## Surprises & Discoveries


The 2026-09-15 source review found obsolete selectors throughout the earlier plan.
`Transition` fields are `source`, `command`, `implementation`, `guard`, `writes`,
`emits`, `outcome`, `outcomeDuplicateLocs`, `goto`, `mode`, and `loc`.
ADR 0038 requires record-dot reads and explicit reconstruction helpers; the package
does not enable OverloadedRecordUpdate. WorkspaceSpec uses `mergedSpec`, not
`wsMergedSpec`. The private canonical clause renderers are not exported.

Exact cancellation alone cannot supply the guard unions. For example, old guards
`a || b` and `a`, versus new guard `a || b`, leave an old-only `a` after
cancellation. That remainder is covered by the surviving live guard. Calling it a
removed body would be false. Likewise, any one old guard is not necessarily a superset
of a multi-sibling removed region; coverage must account for every old alternative.

`renderSource :: ParsedSource -> Text` cannot consume a CheckedService.
`checkedServiceWithSpec :: Spec -> CheckedService -> CheckedService` preserves the
effective language and rebuilds analyses, but does not validate the replacement.
CheckedService intentionally does not preserve source declarations. The gate must
construct a synthetic ParsedSource with an explicit version taken from
`checkedLanguageContract`, not pretend it recovered a member's original preamble.

The current `guardImplies` in ReplayImpact recognizes identity, Boolean atom
true/false, conjunction elimination, and disjunction introduction. It does not prove
`g => (g && a) || (g && !a)`. The earlier promised split example therefore exceeded
the accepted fragment. A split of an explicit `a || b` into guards `a` and `b`
can instead be handled by deterministic top-level disjunction alternatives.

`remediationFor :: ChangeContext -> DiagnosticCode -> NonEmpty Remedy` has no
finding detail parameter. It can assign generic do-not-deploy guidance, while the
specific parse or validation error belongs in ChangeKind.detail. Advisory guidance
does not itself change the CLI exit status.

The older plan claimed that every pair of same-mode edges sharing a first emitted
constructor is rejected regardless of guards. That is not an appropriate assumption:
current source in `mori://shinzui/keiki/packages/keiki` includes a conservative
register-disjointness analysis in `inversionAmbiguityWarnings`. More fundamentally,
Keiro's validateService is a source gate, not assembled Keiki runtime validation.
Neither body classification nor twin coverage may depend on a claim that all
same-body siblings are impossible. Live-first inversion avoids cross-phase ambiguity,
but does not make arbitrary additional replay-only siblings safe within their phase.

A wholly removed family is not automatically covered by an event-retirement diagnostic.
`ReplayOnlyCommandStillLive` is a warning emitted only when a replay-only edge
already exists; retained event declarations alone do not establish history coverage.
Include old-only families in removed-body classification whenever the aggregate survives.


## Decision Log


Decision (2026-08-22, retained): deliver structural body classification and validated
remedies, deferring semantic equivalence and satisfiability. IR-33 rejected a finite-only
proof engine that would withhold useful twins for ordinary Text/Int/Time/ID guards.
An undecided generated guard relation still has an exact syntactic removed-region twin.

Decision (2026-09-15): use EP-265's exact deltas as a work-selection boundary, then recover
complete old/new family members for union comparison. Candidate replay-only members are
always read from the full aggregate. This preserves cancelled coverage and separates mode
partitioning from cross-mode remedy lookup.

Decision (2026-09-15): normalize only the temporary comparison list of top-level OR
alternatives: flatten EOr, sort and deduplicate by canonicalExpr, absorb a true guard,
and reconstruct a right-nested EOr when needed. This is comparison-local union
construction, not rewriting declared expressions or canonical fold bytes. Do not
distribute AND, prove excluded middle, or introduce a semantic solver.

Decision (2026-09-15): a single same-body replay-only edge covers a body if its guard
is the computed twin, the complete old union, absent/true, or a guard that every old
alternative implies through the shared syntactic fragment. A single old sibling guard
does not suffice unless it covers all alternatives. Keep coverage conservative; combining
several partial replay-only guards is deferred. Coverage suppresses the advisory only,
not independent replay-audit or snapshot effects.

Decision (2026-09-15): removed generated emitting bodies include entirely old-only
families inside a matched aggregate. Their twin carries the complete old union.
Deleted aggregates remain owned by removedAggregateDiff and replay-impact removal.
Warnings about retired commands are permitted by the source-remedy gate.

Decision (2026-09-15): affected old Hole-owned behavior cannot be copied or proved
covered from its structural envelope. Emit one AggGuardRelationUnknown per affected
family involving unmatched old Hole behavior or a generated/Hole ownership switch
for the same event envelope; suppress guessed body remedies for that ambiguous family.
Unchanged exactly cancelled Hole transitions create no new guard finding; newly added
Hole bodies alone are additive. No claim about invisible hand-written code changes is made.

Decision (2026-09-15): migrate live generated-body replay classification as well as
sharing guardImplies. Importing the helper alone would leave one-to-one cancellation
unable to recognize a split/merge that diff calls preserved. Preserve existing
independent audit causes and replay-only deletion handling.

Decision (2026-08-22, clarified 2026-09-15): keep the guard pass in aggregatePairDiff
at its current emission position. Carry both CheckedServices through DiffEnv and
derive its Spec fields from them. Preserve ordering relative to other passes;
within the guard pass order by family key then body key.

Decision (2026-09-15): validate remedies under the effective language using a synthetic
ParsedSource. Compare canonical replay identity plus cleared outcome fields after parsing,
rather than relying on raw AST equality across expression representations.
Detailed errors belong in the finding; remediationFor retains its existing signature.
These are proposed implementation decisions; amend accepted ADRs when implementation lands.


## Outcomes & Retrospective


The plan has been refreshed for implementation after EP-265. Source inspection corrected
API names and argument order, union/cancellation interactions, multi-sibling coverage,
Hole opacity, removed-family handling, replay-impact integration, and the limits of the
source round-trip proof. EP-266 production work remains unimplemented. EP-265 was still
open and its TransitionFamily module absent at the start of this refresh; its eventual
field names must be read from the completed implementation. No runtime acceptance is
claimed by this documentation update. During the final check, the concurrent EP-265
implementation added TransitionFamily.hs and wired both consumers to it; its fields
match the handoff below. EP-265 completion and its tests still need to finish before
EP-266 implementation begins. This update did not edit those concurrent code changes.
Documentation validation passed: plan-scoped git diff --check, required section order
by inspection, and an automated check for required sections and tagged, balanced fences.
No build or test suite was run for this plan-only update during concurrent EP-265 work.


## Context and Orientation


A transition family groups one mode, source state, and command. EP-265's internal
`keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs` supplies
`transitionFamilyDeltas :: [Transition] -> [Transition] -> [TransitionFamilyDelta]`.
The in-progress implementation inspected at the final refresh exposes key fields
`familyMode`, `familySource`, and `familyCommand`, and delta fields `familyKey`,
`oldRemainder`, and `newRemainder`. Its `transitionFamilyKey` and `transitionFamilies`
helpers are private to the module. Extend those helpers locally when recovering full
members; do not assume they are already exported to Diff or ReplayImpact.
It returns the union of keys, including fully cancelled families, with duplicate-aware
exact remainders sorted by canonicalTransition. TransitionMode lacks Ord; retain its
explicit mode rank. Keep this module private under other-modules in
`keiro-dsl/keiro-dsl.cabal`; test through public APIs rather than importing it from
`keiro-dsl/test/Main.hs`.

A guard is a Boolean condition; an absent guard means true. A replay body contains
`implementation`, ordered `writes`, ordered `emits`, and `goto` within one
source/command family. Mode, guard, location, and forward outcome are excluded.
Only emitting live bodies enter guard-history classification. A removed region is the
old union O AND the complement of the new union N; removed bodies use O alone.

`keiro-dsl/src/Keiro/Dsl/CanonicalEncoding.hs` exposes canonicalExpr and
canonicalTransition, returning Text. Its bytes are frozen. Derive ReplayBodyKey by
reconstructing a transition with guard absent, mode TmLive, outcomes cleared, and
location noLoc, then calling canonicalTransition. This intentionally also contains the
source and command, which are fixed within the family and enforce correct coverage
lookup. It avoids importing private renderers or introducing a second expression encoding.

`keiro-dsl/src/Keiro/Dsl/Diff.hs` owns DiffEnv, diffCheckedSpecs, aggregateDiff,
aggregatePairDiff, guardTighteningDiff, privateCodes, and classifyCompatibility.
`keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` owns changedTransitionEvents and
matchedAggregateImpact; the latter combines transition events with codec, mapped,
non-transition fold, and snapshot causes. `keiro-dsl/src/Keiro/Dsl/DiffReport.hs`
maps codes to remedies and serializes vector/remedies fields.
`keiro-dsl/src/Keiro/Dsl/Validate.hs` owns DiagnosticCode and validateService.

`keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` supplies checkedSpec,
checkedLanguageContract, checkedServiceWithSpec, and checkedSource.
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` supplies ParsedSource and
SourceLanguage constructors. PrettyPrint.hs supplies renderSource/renderTransition;
Parser.hs supplies parseSource; Grammar.hs supplies complementExpr and noLoc.
Workspace.hs composes members into WorkspaceSpec.mergedSpec with one effective
language contract. Round-tripping that merged graph is an in-memory proof and never
rewrites workspace members.

Relevant local ADRs are
[0002](../adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md)
(live-first replay and retained-edge lifecycle),
[0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
(independent source, diff, runtime and audit gates),
[0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
(effective versus declared language),
[0017](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
(opaque Hole behavior),
[0018](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md)
(frozen canonical bytes and replay ordering), and
[0038](../adr/0038-keiro-dsl-records-use-concise-labels-without-product-selectors.md)
(record-dot and constructor boundaries). Their relevant rules are summarized above.

[ExecPlan 143](143-add-first-class-replay-only-transitions-for-guard-evolution.md)
supplies the runtime safety regression: history fails without its twin, succeeds with
the twin, and new commands in the removed region remain rejected. Adopter evidence is
at `mori://shinzui/mori/plans/223-move-the-mori-workspace-to-keiro-dsl-language-5`
and `mori://shinzui/mori/plans/236-model-project-releases-in-the-registry`.
Locate `mori://shinzui/mori/repos/mori` with Mori and test only a disposable clone.


## Plan of Work


### Milestone 1 — Share complete body unions and syntactic preservation


Extend TransitionFamily.hs without replacing EP-265's exact cancellation. For each
live family with an emitting remainder, select affected body keys from either remainder,
then gather all old/new live members with those keys from the original lists.
An empty member list means an absent body, not an unguarded body. Use NonEmpty
(or an equivalent explicit present/absent representation) for present-body guards;
within a present body, Nothing means true. Never encode both an absent body and true
as Nothing.

Sort and deduplicate top-level OR alternatives by canonicalExpr. A Nothing or literal
true alternative makes the union true; preserve explicit false without requiring
satisfiability analysis. For nontrivial unions use right-nested EOr. Move guardImplies
to this module and give typed ELiteral Boolean constants the same treatment as EAtom
Boolean constants, including Nothing implying explicit true. For preservation, every
old alternative must imply the new union; canonical union equality also proves it.
Preservation is directional: a loosening is safe, not necessarily equivalent.

In ReplayImpact.hs use this same classification for emitting generated live bodies:
preserved/added bodies contribute no guard-derived target; changed/removed bodies
contribute old emitted events and, for a changed body, the same body's new events.
A body replacement contributes both the removed body's and replacement body's events
conservatively within the family. Keep unknown families conservative. Retain EP-265's
comparison for replay-only families and the existing no-emit snapshot treatment.
Existing replay-only coverage does not make an actual live change audit-neutral.

Test publicly through diffServices/replayImpactServices under "replay body". Cover
duplicates, all permutations of three alternatives, outcome/location independence,
body differences, unchanged cancellation survivors, and false/true/unguarded forms.
For diff-specific classification assertions initially add red regressions and turn
them green in Milestone 2; the replay-impact assertions pass at this milestone.
Keep the existing "replay impact" and "transition family" groups green. No canonical,
fingerprint, or parser/scaffold golden may change.


### Milestone 2 — Classify bodies and construct complete remedies


Replace the one-to-one guard path with the shared body classification. Preserved and
added bodies emit no guard finding. Changed generated bodies produce one proposed
twin carrying O AND complementExpr N; when O is true, use complementExpr N alone.
N=true must already classify preserved. Removed bodies use the complete old union O,
including old-only families inside matched aggregates. Choose the representative by
canonicalTransition, copy its body, set mode TmReplayOnly, clear outcome and
outcomeDuplicateLocs, and set loc=noLoc. Do not copy one representative's guard
instead of the union. No-emit bodies never reach remedy generation.

Classify opaque families first, using the Decision Log's Hole rule, and emit one
AggGuardRelationUnknown with no proposed twin. Record aggregate, source/command,
old/new counts, and the ownership reason. Keep the code append-only and its explicit
do-not-deploy mapping from EP-265.

Search the complete candidate for a covering replay-only transition with the same
source, command, and body key. Accept computed-twin equality, complete-old-union equality,
true, or shared-fragment implication from every old alternative to that edge's guard.
Compare through comparison-local union forms/canonicalExpr, not source locations.
Do not accept a single old guard just because it once belonged to that body.
Require the candidate to have no source-validation errors before using coverage as
evidence; cache that validation for the diff invocation.

Add cases for `a || b` split into `a` and `b`, the inverse merge, a duplicated
branch removed, and `a` removed while cancelled `a || b` survives. These require no
distributivity. Keep `g` versus `(g && a) || (g && !a)` conservative with a
mechanical twin; it is explicitly outside the fragment. Source fixtures must validate;
synthetic aggregate mutations may test algebraic edge cases but do not prove assembled
runtime validity.

Also cover a removed emitting body, an entirely removed family with event declarations
retained, guard-plus-emit replacement, stale twin, wrong source/command/write/emit/target/
owner twin, full-old-union twin, and a partial old-sibling twin that must not suppress
a multi-alternative hazard. Exact-cancelled replay-only coverage must still be found.
Keep Plan-143's one-to-one advisory and twin text. Milestone acceptance is passing
"replay body", "transition family", and "plan 143" unit groups, with proposed twins
internally routed to Milestone 3's gate before final release.


### Milestone 3 — Prove every advertised transition under the effective language


Extend DiffEnv with oldService/newService while retaining its old/new Spec views,
derived together in one constructor path. Change private diffCheckedSpecs to accept
the checked services, aggregatePairDiff to accept DiffEnv, and guardTighteningDiff
to receive the candidate context. Keep the public diffServices signature and pass
position unchanged. Cache candidate validation and its unmodified render/parse
preflight once per diff; do not rerun them for every body.

Insert the proposed twin into the matching aggregate in a copied candidate Spec.
Rebuild with checkedServiceWithSpec modifiedSpec candidateService. Construct a
synthetic source using the effective version, as shown in Interfaces and Dependencies.
Render with renderSource, parse with parseSource, and call checkedSource on the result.
Require the same effective contract, no Error diagnostics from validateService, and
preservation of the proposed twin's canonicalTransition with both outcome fields empty.
Canonical transition comparison ignores location and alternate AST representations
that print identically. Also verify that the unmodified merged candidate round-trips
without losing semantic declarations; fixture checks may compare Spec equality where
the parser representation is already stable. Treat failed preflight as unavailable
proof with a precise reason, never as evidence of a real guard relation.

On success emit AggGuardTightened with renderTransition twin. On failure emit
AggGuardRemedyUnavailable instead, naming the potential history hazard and the failed
proof stage. Never claim an unproved region is inhabited. Never include the failed
transition block in detail. Append the code after EP-265's addition, classify it as
DiffDiagnostic, include it in privateCodes and the private-history advisory vector,
and explicitly map it to generic RemedyDoNotDeploy guidance. Store specific errors
in detail; do not change remediationFor's signature to smuggle them into a code-level
mapping. Round-trip and policy-code inventory tests must include it.

Validate all proposed remedies together as well as individually before advertising
a set; any source-validation conflict makes the affected suggestions unavailable.
This still proves only source legality. Same-phase runtime ambiguity, old/new output
hooks, and hand-written behavior require conformance/audit; describe that limit in
guidance and do not advertise an unconditional safe-deploy guarantee.

Use valid old and candidate fixtures for failure tests: remove an event or register
used only by an old removed body so inserting its twin becomes invalid. Preserve the
independent removal finding, assert the unavailable code and reason, and assert no
rendered transition block or replay-only-edge remedy. A production test hook is
unnecessary. Add merged-workspace round-trip preflight and per-language tests for
legacy/explicit Language 1 through 5 using parseSource/checkedSource/validateService,
including a Language-5 accepted outcome cleared from the twin. Pasting a successful
twin must validate and suppress that body's guard finding on re-diff.

Acceptance is passing focused groups and domain-outcomes conformance, including
diagnostic text parsing, JSON vector/remedy mapping, and explicit --deny behavior.


### Milestone 4 — Prove CLI and runtime behavior and record the durable contract


Extend keiro-dsl/test/diff-test.sh with Git-backed self-diff, preservation, changed,
removed-family, exact/verbatim-union coverage, stale coverage, unknown-Hole, and
unavailable cases. Assert the number of guard-history findings by code, not the total
findings: fold, codec, or declaration findings may accompany them. Pin
private-history-read=advisory and remedies in JSON. Default advisories retain the
default exit behavior; --deny AggGuardRemedyUnavailable and --deny
AggGuardRelationUnknown must fail deliberately. DoNotDeploy is guidance, not an
implicit change of severity.

Run the existing Keiro black-acuity/replay-only safety tests unchanged. Multi-sibling
algebraic tests do not replace these compiled runtime proofs. Keep runtime validation
and replay audits independent of source-level coverage.

Build the executable and clone Mori as below. Record the clone's commit. Its HEAD
self-diff must have an empty findings array and replay-neutral verdict. In the clone,
tighten one emitting ObserveProjectDescription branch by conjoining a type-correct
extra condition over a field already present in that branch. Record the actual patch,
filtered guard finding, twin, successful check, and suppression after pasting.
Expect one guard finding naming ProjectDescriptionChanged, not necessarily one total
finding. If the adopter has renamed that branch, select and record the equivalent
existing emitting branch after inspecting its source.

Update docs/guides/evolution-and-replayability.md and keiro-dsl/CHANGELOG.md.
Distill the implemented rules into ADRs 0002, 0004, and 0018, respecting current
profile/log metadata and retaining the source-versus-runtime distinction. EP-265
already owns the unknown code; EP-266 adds only the unavailable code.
After all acceptance gates pass, update IR-33's status/timestamp and append its
Implemented log entry, explicitly retaining the deferred semantic scope.
Milestone acceptance is the full validation bar and recorded adopter evidence.


## Concrete Steps


Run from the Keiro repository root. First inspect EP-265 completion and actual APIs:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
rg -n '^-[[:space:]]+\[ \]' docs/plans/265-make-aggregate-transition-family-diffs-idempotent-and-order-independent.md
sed -n '1,260p' keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs
rg -n 'AggGuardRelationUnknown|\.emits|outcomeDuplicateLocs' keiro-dsl/src/Keiro/Dsl/Diff.hs
```

The first command should return no unchecked Progress items (rg exits 1 for no matches);
read EP-265's completion evidence as well. Do not infer completion merely from a
diagnostic name appearing in source.

```bash
cabal build exe:keiro-dsl
cabal test keiro-dsl-test --test-options='--match "transition family"'
cabal test keiro-dsl-test --test-options='--match "replay body"'
cabal test keiro-dsl-test --test-options='--match "replay impact"'
cabal test keiro-dsl-test --test-options='--match "plan 143"'
cabal test keiro-dsl-conformance-domain-outcomes
bash keiro-dsl/test/diff-test.sh
cabal test keiro-test --test-options='--match "guard tightening"'
cabal test keiro-test --test-options='--match "black-acuity"'
cabal test keiro-test --test-options='--match "replay-only twin"'
```

Each focused group must execute examples, not succeed with zero matches. Build the
CLI before its shell test. Expected new behavior includes:

```text
cancelled survivor covers removed alternative: no guard-history finding
changed generated body: AggGuardTightened with source-validated twin
removed generated family: AggGuardTightened with whole old guard union
partial old-sibling twin: does not suppress whole-body hazard
affected opaque family: AggGuardRelationUnknown without a transition block
invalid inserted twin: AggGuardRemedyUnavailable without a transition block
```

Run the disposable adopter proof:

```bash
cabal build exe:keiro-dsl
keiro_dsl_bin="$(cabal list-bin exe:keiro-dsl)"
mori_source="$(mori path mori://shinzui/mori/repos/mori)"
guard_proof_scratch="$(mktemp -d "${TMPDIR:-/tmp}/keiro-guard-body.XXXXXX")"
git clone --local --no-hardlinks "$mori_source" "$guard_proof_scratch/mori"
cd "$guard_proof_scratch/mori"
git rev-parse HEAD
"$keiro_dsl_bin" diff domain/mori.keiro-workspace --since HEAD \
  --report-out "$guard_proof_scratch/mori-diff.json" \
  --replay-impact-out "$guard_proof_scratch/mori-replay.json"
jq '{breaking, findings: [.findings[] | {code, vector, remedies}]}' "$guard_proof_scratch/mori-diff.json"
jq . "$guard_proof_scratch/mori-replay.json"
```

The unchanged result is `{"breaking":false,"findings":[]}` and
`{"verdict":"replay-neutral"}`. After the experimental edit and again after pasting
the twin, rerun diff and `"$keiro_dsl_bin" check domain/mori.keiro-workspace`.
Record the guard-code count and check result; independent audit/fold findings may
remain after coverage suppresses the guard advisory.

Run the final gates back in Keiro:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal build all
cabal test keiro-dsl:tests
cabal test keiro-test
nix fmt -- --check
git diff --check
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/improvement-requests --strict \
  --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
```

When implementation updates ADR timestamps, append the matching entries with
`okf log add` before strict validation. To close IR-33, update its implementation
status and timestamp using the existing bundle convention, then:

```bash
okf log add docs/improvement-requests IR-33 \
  --kind Implemented \
  --message "Implemented the accepted structural scope of Plans 265 and 266; semantic guard proofs remain deferred in the IR-33 review."
okf validate docs/improvement-requests --strict \
  --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
git diff --check
git status --short
```

Record actual examples, failures, and the pinned adopter commit in Progress and
Outcomes. This refresh does not authorize closing the request before implementation.


## Validation and Acceptance


Identical sources and declaration permutations produce no guard-history code and are
replay-neutral. An unrelated addition does not change an existing body's classification.
Cancelled live and replay-only siblings remain available for coverage. No-emit edits
produce no guard-history finding; they retain existing independent snapshot treatment.

Preserved explicit unions and syntactic loosenings have no guard-derived audit target.
Changed/removed generated bodies produce one guard finding per body, with the exact
whole-union twin when the source gate succeeds. Entire removed families are included
inside matched aggregates. Body replacements conservatively target both sides' events.
Opaque affected families produce one unknown finding without a guessed twin.

Only a same-family, same-body, demonstrably covering candidate replay-only edge suppresses
an advisory. One partial old guard cannot cover all old alternatives. Extra unrelated
siblings do not invalidate coverage evidence, but that does not establish runtime
same-phase determinism. Covered changes may still require targeted replay/snapshot audits.

Every advertised twin preserves its canonical replay body and cleared outcomes through
the effective-language round trip and validates without Error diagnostics, both alone
and with the other advertised twins. Failed proof produces only the unavailable guard
code, with specific detail and generic do-not-deploy guidance. Both unknown and unavailable
codes are diff diagnostics with explicit policy and remedy mappings.

Public signatures, JSON schemas, canonical fold bytes, and Languages 1–5 parser/scaffold
contracts remain unchanged. Existing one-to-one Plan-143 twin text stays pinned.
Finding order relative to other passes stays unchanged; revised guard findings are
deterministic by family/body key. Any necessary rendering-golden change must be explained
by the intended classification change, never by moving the whole pass.

The disposable adopter proof, unchanged compiled runtime proofs, full package tests,
formatting, and strict documentation checks pass. IR-33 closes only for its accepted
structural scope; no semantic-engine completion or unconditional replay safety is claimed.


## Idempotence and Recovery


Comparison, candidate insertion, and validation are pure and operate on copied values.
Repeated diffs never apply a twin or alter stored data. Cache only within the invocation,
keyed to its candidate; never reuse analyses from a different Spec.

Keep changes incremental and leave the release state with one shared classification
authority. If a round-trip fails, retain the truthful unavailable diagnostic and fix
the cause; never bypass validation to preserve a paste-ready golden. Preserve EP-265's
code vocabulary and keep AggGuardRemedyUnavailable append-only after it lands.

Use a new mktemp directory for an interrupted adopter proof. Remove only its recorded
temporary clone when finished; never reset or clean the registered Mori checkout.
Preserve concurrent EP-265 edits and reconcile its actual private APIs when complete.
No feature branch, dependency upgrade, database operation, or consumer-source rewrite
is required.


## Interfaces and Dependencies


The following public signatures are verified against the working tree and remain unchanged:

```haskell
diffServices :: CheckedService -> CheckedService -> Either FoldSurfaceError [Change]

replayImpactServices
  :: CheckedService -> CheckedService -> Either FoldSurfaceError ReplayImpact

checkedServiceWithSpec :: Spec -> CheckedService -> CheckedService
checkedSpec :: CheckedService -> Spec
checkedLanguageContract :: CheckedService -> EffectiveLanguageContract
checkedSource :: ParsedSource -> CheckedService
renderSource :: ParsedSource -> Text
parseSource :: FilePath -> Text -> Either ParseFailure ParsedSource
validateService :: CheckedService -> [Diagnostic]
remediationFor :: ChangeContext -> DiagnosticCode -> NonEmpty Remedy
```

The candidate effective-language adapter is concrete; local variable names below assume
the candidate CheckedService and modified Spec have already been supplied:

```haskell
modifiedService = checkedServiceWithSpec modifiedSpec candidateService
contract = checkedLanguageContract modifiedService
syntheticSource =
  ParsedSource
    { sourceLanguage = DeclaredLanguage contract.contractLanguageVersion noLoc,
      spec = checkedSpec modifiedService
    }
parsedResult = parseSource "<guard-remedy>" (renderSource syntheticSource)
-- On Right parsed, construct checkedSource parsed and inspect validateService.
-- Accept Warning diagnostics; reject every diagnostic whose severity is Error.
```

Private proposed interfaces in TransitionFamily.hs may follow EP-265's actual record
conventions, but must preserve this meaning:

```haskell
replayBodyKey :: Transition -> ReplayBodyKey
guardImplies :: Maybe Expr -> Maybe Expr -> Bool
guardUnion :: NonEmpty (Maybe Expr) -> Maybe Expr
unionPreserved :: NonEmpty (Maybe Expr) -> NonEmpty (Maybe Expr) -> Bool
```

Represent body absence separately from guardUnion; keep original member lists and
canonical-order representatives in body records. A family/body result must expose enough
information for both diff findings and replay targets, without either consumer repeating
pairing or union construction. Helpers remain internal, tested via public observable
behavior. There are no new libraries and no Keiki API or bound changes. The existing
dependency is `mori://shinzui/keiki/packages/keiki`; any future dependency change requires
a separate registry/upstream version check and plan.

Every implementation commit uses a Conventional Commit subject and these trailers:

```text
ExecPlan: docs/plans/266-classify-guard-unions-by-replay-body-and-validate-replay-only-remedies.md
Intention: intention_01m0kst1x4ejdsnxmweqv8brne
```


## Revision note (2026-09-15)


Refreshed all sections against the current APIs and EP-265 prerequisite. Corrected
record fields, effective-language source construction, canonical-key derivation, private
test visibility, and code-level remediation limits. Fixed cancellation-survivor unions,
partial-twin coverage, whole-family removals, Hole opacity, and missing replay-impact
integration. Replaced the unsupported distributive split promise with an explicit-union
test and documented the boundary between source-valid remedies and runtime safety.
Implementation milestones remain open.
