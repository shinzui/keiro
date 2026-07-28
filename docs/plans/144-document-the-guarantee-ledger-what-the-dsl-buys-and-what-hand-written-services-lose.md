---
id: 144
slug: document-the-guarantee-ledger-what-the-dsl-buys-and-what-hand-written-services-lose
title: "Document the guarantee ledger: what the DSL buys and what hand-written services lose"
kind: exec-plan
created_at: 2026-07-28T10:48:59Z
intention: "intention_01kym5dc4ve69sxsjtzd81pbbz"
master_plan: "docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md"
---

# Document the guarantee ledger: what the DSL buys and what hand-written services lose

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro supports two officially sanctioned ways to build a service. The first writes a typed
`.keiro` specification and drives the `keiro-dsl` toolchain (`check`, `scaffold`, `diff`,
generated harness). The second writes everything by hand against the `keiro` and `keiro-core`
libraries — the in-repo example service `jitsurei` is built exactly this way and has no spec.
Both paths are supported, but nowhere in the repository is it written down, in one place aimed
at adopters, precisely which guarantees each path carries. That gap produces two opposite
mistakes: adopters overestimate the hand-written path ("the runtime validates everything
anyway") and roadmap discussions overstate the DSL ("without the spec, reliability collapses").
Neither is true, and the difference matters because the guarantees the hand-written path lacks
fail *silently* — the most dangerous failure mode there is.

After this plan, a reader can open a single new guide,
`docs/guides/dsl-guarantees-and-hand-written-services.md` (the "guarantee ledger"), and see
exactly which guarantees are enforced below the DSL and therefore held by every service, which
exist only in the DSL layer, what a hand-written service concretely gives up (ranked by how
silently each loss bites), and what the DSL's own cross-version guarantee does *not* cover.
Every factual claim in the guide carries a `file:line` citation into this repository's working
tree, so the guide can be re-verified mechanically and can never drift into aspiration. The
same plan also corrects the justification framing of improvement request IR-1
(`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`): the
argument for IR-1's strictness is "no false confidence" — a structural diff over a schema the
runtime does not execute is *worse* than the honest hand-written path — layered on top of
replay soundness that is enforced below the DSL either way. It is not "hand-written services
are unreliable." Finally, the new guide is cross-linked from `docs/guides/README.md` and
`docs/guides/evolution-and-replayability.md` so readers actually find it.

You can see it working by opening the new guide, following any citation to the named file and
line, and confirming the source says what the guide claims; and by reading IR-1's revised
Context, which now argues from false confidence rather than from collapse.

This is ExecPlan EP-1 of MasterPlan 25
(`docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md`).
It is documentation-only: no Haskell code, no `.keiro` specs, and no generated files change.


## Progress

- [ ] Milestone 1: guarantee ledger guide drafted at `docs/guides/dsl-guarantees-and-hand-written-services.md` with all named sections and verified `file:line` citations.
- [ ] Milestone 2: IR-1 justification reframed (Context/Status prose only; constraints untouched; frontmatter `timestamp` advanced).
- [ ] Milestone 3: cross-links landed in `docs/guides/README.md` and `docs/guides/evolution-and-replayability.md`; all links verified to resolve.
- [ ] Proposal Test passage answered in this plan's Validation and Acceptance against the finished guide.
- [ ] Final citation re-verification pass against the working tree at completion time.
- [ ] ADR distillation pass considered (expected outcome: no new ADR; see Decision Log).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Name the guide `docs/guides/dsl-guarantees-and-hand-written-services.md` and call
  it "the guarantee ledger" in its title and in cross-links.
  Rationale: The filename states both subjects (what the DSL guarantees, what hand-written
  services carry) so it is discoverable from the guides index; "guarantee ledger" is the term
  MasterPlan 25 and the research note already use for this deliverable, so cross-references
  stay coherent.
  Date: 2026-07-28

- Decision: The guide complements and cross-links the existing gate-coverage summary table in
  `docs/guides/evolution-and-replayability.md` (lines 552-576) instead of duplicating it.
  Rationale: That table already maps change classes onto gates and names several silent risks.
  Duplicating it would create two tables that drift apart. The ledger's distinct contribution
  is the *layered* view (which guarantees live below the DSL versus only in it), the ranked
  losses of the spec-less path, and the honest limits of the DSL's own diff — none of which the
  table covers.
  Date: 2026-07-28

- Decision: Frame the hand-written path as officially sanctioned throughout, and rank its
  losses by silence (silent wrong state first, loud-in-production last), not by frequency or
  effort.
  Rationale: `jitsurei`, the repository's own teaching service, has no spec; the docs corpus
  cannot describe the spec-less path as deprecated or unsound without contradicting itself.
  Silence is the correct ranking axis because a loss that produces a typed runtime error is
  recoverable by an operator, while a loss that serves wrong state without any error is not
  discoverable at all.
  Date: 2026-07-28

- Decision: Reframe IR-1's justification as "no false confidence layered on soundness enforced
  below the DSL," never as "reliability collapses without the DSL"; touch only framing prose
  and the frontmatter timestamp, leaving every constraint, contract, and acceptance item in
  IR-1 unchanged.
  Rationale: MasterPlan 25's Integration Points section assigns exactly this to EP-1 ("EP-1
  records the reframed justification (layered soundness, no-false-confidence) in IR-1
  itself"). The stronger claim is factually wrong — keiki `validateTransducer` and
  `ValidatedEventStream` enforce replay soundness for every service, spec or no spec — and a
  documentation corpus that overstates its own tooling fails the research note's own test
  (a claim of enforcement the code does not execute is exactly the false confidence IR-1
  exists to prevent).
  Date: 2026-07-28

- Decision: Present the DSL's cross-version guarantee as partial — a matter of degree, not a
  binary — with the hole-body and upcaster-body blind spots stated explicitly in the guide.
  Rationale: `keiro-dsl diff` parses two revisions of `.keiro` *text* only
  (`keiro-dsl/app/Main.hs:150-175`); hand-owned Holes code and upcaster bodies behind
  `ev-upcast-from` holes are invisible to it. A ledger that presented "DSL = checked,
  hand-written = unchecked" as a binary would itself be a false-confidence document.
  Date: 2026-07-28

- Decision: Validate links manually (and with a small ad-hoc grep pass) rather than adding
  link-check tooling.
  Rationale: The repository's `Justfile` has no markdown link-check recipe (its docs recipe is
  `adr-validate`, an OKF profile check scoped to `docs/adr/`). Adding tooling is out of scope
  for a documentation plan; the Concrete Steps section gives an exact manual procedure.
  Date: 2026-07-28


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This section is self-contained: everything needed to write the guide accurately is stated
here, with the file and line evidence that must be re-verified (the tree moves; re-check each
citation before relying on it) and then carried into the guide itself.

### The repository and its two authoring paths

This repository (`/Users/shinzui/Keikaku/bokuno/keiro`, referred to below by repo-relative
paths) is a Cabal multi-package workspace. The packages that matter here:

- `keiro-core/` — the validated event-stream boundary and core types.
- `keiro/` — the runtime: command runner, snapshots, replay audit, telemetry.
- `keiro-dsl/` — the spec toolchain: parser, `check`, `scaffold`, `diff`, harness generation.
- `jitsurei/` — the in-repo example service, written entirely by hand with **no** `.keiro`
  spec. Its existence is the proof that the hand-written path is officially sanctioned.

Keiro services are event-sourced: the append-only event log is the only durable state, and
current state is reconstructed by *replay* — re-folding stored events through a transducer (a
typed state machine from the sibling `keiki` library, checked out at
`/Users/shinzui/Keikaku/bokuno/keiki`, whose transducers define guards, state transitions, and
register updates). A "register" is a named typed slot of aggregate state; an "upcaster" is a
function that migrates an old stored event-payload version to the next version at decode time;
a "snapshot" is a cached fold result used to skip replay prefixes; "hydration" is the act of
loading and replaying a stream to serve a command.

A *DSL service* writes a `.keiro` specification and runs `keiro-dsl` to validate it
(`check`), generate the deterministic ring of modules plus typed holes (`scaffold`), classify
changes between two spec revisions (`diff --since <git-ref>`), and generate a conformance
harness. A *hand-written service* writes all of that directly in Haskell. Both compile against
the same runtime.

### The layered gate model (ADR 0004 and the evolution guide)

The governing architectural decision is
`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`: every evolution
hazard is checked at the earliest boundary that has enough evidence to decide it soundly, and
later boundaries independently defend runtime assembly rather than trusting earlier layers.
The adopter-facing rendering of that decision is the six-gate model in
`docs/guides/evolution-and-replayability.md` (the section "The gates, at a glance", lines
62-110 at the time of writing): (1) the compiler; (2) `keiro-dsl check`/`diff` — DSL services
only; (3) the generated harness — DSL services only; (4) `mkEventStream` /
`mkEventStreamOrThrow` validation at startup; (5) the real-log replay audit
(`Keiro.ReplayAudit`); (6) runtime witnesses (typed hydration errors and advisory
post-append replay-verification telemetry). The same guide ends with a gate-coverage summary
table (lines 552-576) mapping each change class onto these gates and flagging silent risks.
The ledger must complement that table, not restate it.

Two further ADRs supply context the ledger cites:
`docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md` (a snapshot is
valid only when the state-codec version, the keiki shape hashes, and the fold fingerprint all
match — the "three-component discriminator") and
`docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`
(tightening a guard must ship with a replay-only twin edge so old logs still replay). No
existing ADR covers the ledger's subject itself; this plan is expected to produce no new ADR
(documentation of existing decisions, not a new decision — revisit in the distillation pass).

### Ground truth the ledger asserts, with evidence

**Replay soundness is enforced below the DSL and is therefore universal.** Keiki's
`validateTransducer` (exported from `/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs`;
the warning vocabulary begins at line 1793 and the function itself at lines 1948-1953)
structurally rejects transducers whose logs could not be replayed: `HiddenInput` (an edge
consumes command data its emitted events do not carry), `HeadUnrecoverable` (a multi-event
edge whose first event cannot recover the command), `InversionAmbiguity` (two edges share a
first wire constructor, so replay cannot tell which produced an event),
`UnguardedInputRead` (a field read not protected by a constructor guard), and
`StateChangingEpsilon` (a state change that emits no event at all). Keiro-core then makes
passing these checks unavoidable: `ValidatedEventStream`
(`keiro-core/src/Keiro/EventStream/Validate.hs`, lines 74-81) is a newtype whose constructor
is deliberately not exported — command runners *require* it, and the only exported ways to
obtain one run the validation. `forceReplayContract` (same file, lines 122-128) force-enables
the head-recoverability and state-changing-epsilon checks regardless of caller options,
because events are keiro's only durable state. The single bypass, `mkEventStreamUnchecked`
(same file, lines 186-189), is documented in source as existing "only for tests and emergency
forensics." A hand-written service gets all of this; a spec buys none of it, because it was
never the spec's to sell.

**Cross-version safety exists only in the DSL — and even there it is partial.** `keiro-dsl
diff` (`keiro-dsl/app/Main.hs`, lines 150-175) retrieves the old spec via
`git show <ref>:<path>`, parses both revisions of the `.keiro` *text*, and classifies changes
via `keiro-dsl/src/Keiro/Dsl/Diff.hs` (decode/identity-surface classification),
`keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` (replay-impact verdicts), and
`keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs` (the fold fingerprint derived from the spec's
transition surface), exiting non-zero on any BREAKING change. Nothing in this pipeline sees
Haskell: the bodies of hand-owned holes and the bodies of upcasters declared behind
`ev-upcast-from` holes are invisible to the differ. The DSL's guarantee is therefore a matter
of degree — it covers the spec-visible surface completely and the hole surface not at all —
and the ledger must say so, because a reader who believes `diff` checks everything holds
exactly the false confidence this initiative exists to prevent. There is no analogue of any of
this for a hand-written service: with no old spec and no new spec, there is nothing to diff.

**What the hand-written path loses, ranked by silence.** Rank 1 — *silent wrong state*, no
error ever: (a) stale snapshots served after a fold change. The DSL wires the fold fingerprint
into the snapshot discriminator automatically — `withFoldFingerprint`
(`keiro/src/Keiro/Snapshot/Codec.hs`, lines 64-69; doc comment from line 56) composes a fold
identity into the state-shape hash, and the scaffolder emits the call plus a warning comment
(`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, `stateCodecExpr` at lines 1846-1855 and the generated
comment block at lines 1857-1869) — while a hand-written service must remember to bump
`stateCodecVersion` manually on every fold-semantics change, and forgetting serves stale state
with zero errors. (Note the generated comment's own honesty: fold changes made only in the
Holes module are invisible to the fingerprint too — the DSL narrows this window, it does not
close it.) (b) Field removal under a tolerant codec: the decoder still succeeds, meaning
drifts silently; the DSL classifies the removal BREAKING at gate 2, the hand-written service
has no gate before production behavior. (c) Durable-workflow body reorder without a recorded
patch: journaled steps pair with the wrong ordinals — silent for hand-written ordinals (see
the "Workflow body reorder" row of the evolution guide's summary table). Rank 2 — the
*unrecoverable golden-capture window*: `keiro-dsl diff --emit-goldens` synthesizes old-shape
payload fixtures, and per the module documentation of `keiro-dsl/src/Keiro/Dsl/Goldens.hs`
(lines 1-7) "the current aggregate specification cannot reconstruct an older payload shape, so
golden payloads are synthesized while both the old and new specifications are available." A
hand-written service that missed capturing an old wire shape before changing the code has no
mechanism to reconstruct it — the window closes permanently. Rank 3 — *loud failures move
from CI to production*: the generated harness (gate 3) round-trips shapes and decodes old
goldens in CI; without it, the first witness of a codec mistake is a typed runtime error
during hydration — `HydrationDecodeFailed` (`keiro/src/Keiro/Command.hs`, constructor
documented at lines 175-177 within the `CommandError` block spanning roughly 175-215, raised
during hydration decode at lines 469-473). Loud, typed, recoverable — but in production, on
the next touch of affected data. Rank 4 — *the replay audit degrades*: `Keiro.ReplayAudit`
selects affected streams from the spec-derived `diff --replay-impact-out` set; per its module
documentation (`keiro/src/Keiro/ReplayAudit.hs`, lines 15-16), "hand-written services have no
spec from which to derive an affected set. They must supply a conservative set explicitly or
choose 'AuditFull'" (`AuditFull`, defined at line 82, is reserved for one-time cutovers and
forensics per lines 7-8).

**What the hand-written path keeps.** The compiler (gate 1, exhaustiveness over event and
command types); the full `mkEventStreamOrThrow` startup validation described above, including
codec construction checks (invalid versions, duplicate tags, incomplete upcaster chains fail
validated construction); the replay audit itself (gate 5) with an explicitly supplied affected
set; typed runtime failures (`HydrationDecodeFailed`, `HydrationReplayFailed` and its reasons,
`EncodeFailed` — all in `keiro/src/Keiro/Command.hs`); and the default-on advisory post-append
replay verification, which re-plays each just-committed batch and, on divergence, increments a
counter and stamps a `keiro.replay.divergence` attribute on the command span — advisory
telemetry only: the command still succeeds and nothing is dead-lettered
(`docs/guides/evolution-and-replayability.md`, lines 102-110). The ledger must repeat that
guide's warning verbatim in spirit: if you do not alert on that counter, this witness does not
exist for you.

### The IR-1 reframing

IR-1, `docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`
(frontmatter `requestId: IR-1`, `status: proposed`, `timestamp: 2026-07-28T00:11:06Z`),
requests structural and opaque consumer-owned type bindings for `keiro-dsl`. Its Status
section already contains the seed of the correct framing: "a Keiro declaration cannot
truthfully claim structural control while delegating the same structure to an arbitrary
consumer `ToJSON` or `FromJSON` instance." The research note
`docs/research/14-structural-consumer-type-tradeoffs.md` sharpens it (section 1): a diff that
reasons about a wire key the runtime never emits "is worse than having no structural check
because the tool reports false confidence." The reframing this plan lands makes that the
explicit justification arc in IR-1's Context: replay soundness is already enforced below the
DSL for every service (keiki validation plus `ValidatedEventStream`); the DSL adds
cross-version evolution checking on top; IR-1's strictness exists so that this added layer
never claims a schema the executed codec does not honor — because a false structural claim is
strictly worse than the honest, sanctioned hand-written path. What must *not* change: IR-1's
Design Principles, The Request, Usage Boundaries, Keiki constraints, Evolution Contract,
Validation and Scaffolding Contract, Conformance Harness Contract, Acceptance, Compatibility
Baseline, Out of Scope, and References sections all stay byte-identical except where a
sentence is purely framing; the frontmatter `timestamp` advances to the revision date. The
existing `reviews` entry records a model review of the 2026-07-28T00:11:06Z document; it is
historical provenance and stays untouched.

### Which sections of the normative references this plan implements

Of the research note (`docs/research/14-structural-consumer-type-tradeoffs.md`), this plan
implements the documentation consequences of "The Guarantees We Are Protecting" (G1-G6, which
the ledger summarizes for adopters), section 1's false-confidence argument (carried into
IR-1's reframed Context), and "A Proposal Test for Future Keiro Improvements" (applied to
this plan itself in Validation and Acceptance). Of IR-1, this plan implements no requested
capability; it revises only the framing prose of the Status/Context sections as assigned to
EP-1 by MasterPlan 25's Integration Points ("EP-1 records the reframed justification (layered
soundness, no-false-confidence) in IR-1 itself"). The ledger also serves MasterPlan 25's
Vision & Scope paragraph beginning "The initiative also closes a documentation gap."

### Related work this plan must not absorb

MasterPlan 25's EP-3 (`docs/plans/146-...`, Not Started) will give hand-written services a
first-class fold-fingerprint helper, shrinking the ledger's rank-1(a) loss. The ledger
documents today's truth and may note that the loss is targeted by that plan, but must not
describe the helper as existing. EP-2 (`docs/plans/145-...`) is the brownfield guide, which
soft-depends on this plan and will link into the ledger's layered-gate exposition.


## Plan of Work

The work is three milestones, each independently verifiable, all documentation-only.

### Milestone 1 — Write the guarantee ledger guide

Scope: create `docs/guides/dsl-guarantees-and-hand-written-services.md`. At the end of this
milestone a complete, citation-backed guide exists that did not exist before; nothing else in
the tree has changed. Acceptance: the guide contains the named sections below, every factual
claim about code behavior carries a repo-relative `file:line` citation (or a keiki absolute
citation clearly marked as the sibling checkout — prefer citing the keiki module path
`src/Keiki/Core.hs` with the project named), and each citation checks out against the working
tree.

Write the guide in prose with these sections, in this order:

1. An introductory section stating the guide's purpose and its two audiences (an adopter
   choosing a path; a maintainer arguing about the DSL's value), and stating up front that
   both paths are officially sanctioned — `jitsurei` has no spec.
2. "The layered gate model" — a compact restatement of the six gates, explicitly linking
   `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` and the
   evolution guide's "The gates, at a glance" section, and drawing the layer boundary: gates
   1, 4, 5, 6 exist for every service; gates 2 and 3 exist only for DSL services.
3. "What is enforced below the DSL (and therefore held by every service)" — keiki
   `validateTransducer` with the five replay-soundness check families named and explained in
   one sentence each (HiddenInput, HeadUnrecoverable, InversionAmbiguity, UnguardedInputRead,
   StateChangingEpsilon; keiki `src/Keiki/Core.hs:1793-1980`), and keiro-core's unexported
   `ValidatedEventStream` constructor, `forceReplayContract`, and the `mkEventStreamUnchecked`
   forensics bypass (`keiro-core/src/Keiro/EventStream/Validate.hs:74-189`, with the tighter
   line ranges from Context and Orientation).
4. "What exists only in the DSL — and how far it reaches" — the `diff` pipeline
   (`keiro-dsl/app/Main.hs:150-175`, `Diff.hs`, `ReplayImpact.hs`, `FoldFingerprint.hs`), the
   golden-emission mechanism, and then, without hedging, the blind spots: hole bodies and
   upcaster bodies are invisible; the guarantee is a matter of degree, not a binary. Cross-link
   ADR 0002 and ADR 0003 where guard tightening and the snapshot discriminator come up.
5. "The ledger: what a hand-written service gives up, ranked by silence" — the four ranks
   from Context and Orientation, each with its citation: (1) silent wrong state (manual
   `stateCodecVersion` bumps versus `withFoldFingerprint` wiring,
   `keiro/src/Keiro/Snapshot/Codec.hs:56-69` and `keiro-dsl/src/Keiro/Dsl/Scaffold.hs:1846-1869`,
   including the Holes-invisibility caveat; tolerant-codec field removal; workflow body
   reorder); (2) the golden-capture window (`keiro-dsl/src/Keiro/Dsl/Goldens.hs:1-7`);
   (3) loud failures move from CI to production (`HydrationDecodeFailed`,
   `keiro/src/Keiro/Command.hs:175-215` and `469-473`); (4) replay audit degrades to an
   explicit conservative set or `AuditFull` (`keiro/src/Keiro/ReplayAudit.hs:15-16,82`).
   Note that EP-3 (plan 146) targets loss 1(a) but has not landed.
6. "What a hand-written service keeps" — compiler, full startup validation via
   `mkEventStreamOrThrow`, the replay audit with an explicit set, typed runtime failures, and
   the advisory post-append replay verification with the alerting caveat: the
   `keiro.replay.divergence` witness exists only if you alert on it
   (`docs/guides/evolution-and-replayability.md:102-110`).
7. "How this relates to the gate-coverage table" — a short section pointing at the summary
   table in `docs/guides/evolution-and-replayability.md` (lines 552-576) and stating the
   division of labor: the table maps change classes to gates; this ledger maps *authoring
   paths* to guarantee layers. No rows are duplicated.
8. "Verifying this guide" — one paragraph telling the reader every claim carries a citation
   and inviting them to re-check citations after pulling, since line numbers drift.

Throughout, follow the writing rules of this repository's ExecPlan/guide culture: prose over
tables, every term of art defined at first use (replay, register, upcaster, snapshot,
hydration, hole, golden), and any code excerpt in a language-tagged fence.

### Milestone 2 — Reframe IR-1's justification

Scope: edit `docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`.
At the end, IR-1's Status and Context prose argues from layered soundness and no-false-
confidence; its normative sections are unchanged; the frontmatter `timestamp` reads the
revision date. Acceptance: a `git diff` of the file shows changes confined to the frontmatter
`timestamp` line and framing prose in the Status/Context sections; the Design Principles, The
Request, Usage Boundaries, Keiki and Functional Event-Sourcing Constraints, Evolution
Contract, Validation and Scaffolding Contract, Conformance Harness Contract, Acceptance,
Compatibility Baseline, Out of Scope, and References sections are byte-identical.

Concretely: in the Context section, after the existing paragraph explaining that treating
values as unexamined external types "is honest only when Keiro also treats their wire
representation as opaque," add or rework a short passage stating the layered argument
explicitly — replay soundness is enforced below the DSL for every service by keiki
`validateTransducer` and keiro-core's `ValidatedEventStream` boundary; the DSL's distinct
contribution is cross-version evolution checking; and the reason for IR-1's strictness is that
a structural diff over a schema the runtime does not execute produces false confidence, which
is worse than the sanctioned hand-written path with no diff at all. Where existing prose
implies the stronger claim (that correctness or reliability depends on the DSL), soften it to
the layered claim. Add a cross-reference to the new guide by repo-relative path
(`docs/guides/dsl-guarantees-and-hand-written-services.md`). Advance the frontmatter
`timestamp` to the revision moment in the same UTC format already used
(`2026-07-28T00:11:06Z` becomes the current UTC time). Do not touch the `reviews` block, the
`status`, the `requestId`, or the `origin`.

### Milestone 3 — Cross-link the guide

Scope: two small edits. At the end, the guide is reachable from the guides index and from the
evolution guide. Acceptance: both links resolve to the new file; the evolution guide's
existing content is otherwise unchanged.

In `docs/guides/README.md`, add one bullet to the guide list (a natural position is adjacent
to the "Typed Specifications" and "Evolve Events Safely" entries) with a one-line description:
the guarantee ledger — which guarantees are enforced below the DSL for every service, which
exist only in the DSL, and what a spec-less service gives up. In
`docs/guides/evolution-and-replayability.md`, add a short pointer sentence at the end of "The
gates, at a glance" section (after the sentence about the summary table, around line 109-110)
directing readers comparing the DSL and hand-written paths to the ledger by relative link.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.

First, re-verify every citation before writing, because line numbers may have drifted since
this plan was authored. For each claim, open the cited file at the cited region and confirm
the code or prose says what Context and Orientation states. A fast spot-check:

```bash
grep -n "## The gates, at a glance" docs/guides/evolution-and-replayability.md
grep -n "## Gate coverage summary" docs/guides/evolution-and-replayability.md
grep -n "withFoldFingerprint ::" keiro/src/Keiro/Snapshot/Codec.hs
grep -n "stateCodecExpr" keiro-dsl/src/Keiro/Dsl/Scaffold.hs
grep -n "HydrationDecodeFailed" keiro/src/Keiro/Command.hs
grep -n "AuditFull" keiro/src/Keiro/ReplayAudit.hs
grep -n "mkEventStreamUnchecked" keiro-core/src/Keiro/EventStream/Validate.hs
grep -n "validateTransducer ::" /Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs
grep -n "run (Diff" keiro-dsl/app/Main.hs
```

Expected output shape (line numbers current as of 2026-07-28; treat drift as a signal to
update the guide's citations, not as an error):

```text
62:## The gates, at a glance
552:## Gate coverage summary
64:withFoldFingerprint :: Text -> StateCodec state -> StateCodec state
1846:stateCodecExpr :: Agg -> Text
177:      HydrationDecodeFailed !CodecError
82:    = AuditFull
186:mkEventStreamUnchecked ::
1948:validateTransducer ::
150:run (Diff fp ref emitGoldensRoot replayImpactOut) = do
```

Then write the guide (Milestone 1) at
`docs/guides/dsl-guarantees-and-hand-written-services.md` following the section plan above.
Then edit IR-1 (Milestone 2) and take the current UTC timestamp for its frontmatter with:

```bash
date -u +%Y-%m-%dT%H:%M:%SZ
```

Then add the two cross-links (Milestone 3). After each milestone, verify links from the
changed files resolve. There is no markdown link-check recipe in the `Justfile` (its only docs
recipe is `adr-validate`, scoped to `docs/adr/`), so check manually:

```bash
grep -oE '\]\(([^)#]+)' docs/guides/dsl-guarantees-and-hand-written-services.md \
  | sed 's/](//' | sort -u \
  | while read -r p; do [ -e "docs/guides/$p" ] || echo "MISSING: $p"; done
```

Expected output: nothing (every relative link target exists). Run the same loop for the two
edited files, adjusting the base directory for `docs/improvement-requests/` links if any are
added there. Confirm the docs-only invariant — the diff must touch no Haskell, spec, or
generated file:

```bash
git status --short
```

Expected: only the new guide, the two edited guides files, IR-1, and this plan file appear.
Since `docs/adr/` is untouched, `just adr-validate` is unaffected, but running it is a cheap
regression check:

```bash
just adr-validate
```

Expected: exits zero. Commit per repository convention (Conventional Commits), e.g.:

```text
docs(guides): add the guarantee ledger and reframe IR-1 as no-false-confidence
```


## Validation and Acceptance

Acceptance is observable and mechanical. The plan is done when all of the following hold:

1. `docs/guides/dsl-guarantees-and-hand-written-services.md` exists and contains, verifiable
   with `grep -n '^#' docs/guides/dsl-guarantees-and-hand-written-services.md`, headings
   covering: the layered gate model; what is enforced below the DSL; what exists only in the
   DSL and its limits; the ranked ledger of hand-written losses; what hand-written services
   keep; the relation to the gate-coverage table; and how to verify the guide.
2. Every claim in the guide about code behavior carries a `file:line` citation, and a reader
   who opens each cited location finds source that supports the claim. Spot-check at minimum:
   the unexported `ValidatedEventStream` constructor and `forceReplayContract`
   (`keiro-core/src/Keiro/EventStream/Validate.hs`), `withFoldFingerprint`
   (`keiro/src/Keiro/Snapshot/Codec.hs`), the Goldens module doc
   (`keiro-dsl/src/Keiro/Dsl/Goldens.hs`), the ReplayAudit hand-written sentence
   (`keiro/src/Keiro/ReplayAudit.hs`), and `validateTransducer` warnings (keiki
   `src/Keiki/Core.hs`).
3. Every relative markdown link in the new guide, the edited `docs/guides/README.md`, the
   edited `docs/guides/evolution-and-replayability.md`, and the edited IR-1 resolves to an
   existing file (the grep loop in Concrete Steps prints nothing).
4. IR-1's diff is confined to the frontmatter `timestamp` and framing prose; the phrase
   pattern asserting collapse-without-the-DSL appears nowhere; its Context argues layered
   soundness plus no-false-confidence and links the new guide. Verify the untouched-sections
   claim with `git diff -- docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`
   and confirm no hunk lands inside the normative sections listed in Milestone 2.
5. The working-tree diff contains no changes outside `docs/`.
6. The guide nowhere claims the DSL enforces something it does not: in particular it states
   that `diff` sees only spec text (hole and upcaster bodies invisible), that the post-append
   replay verification is advisory telemetry that fails nothing, and that EP-3's fold-
   fingerprint helper for hand-written services does not yet exist.

**Soundness gate — the Proposal Test applied to this plan.** The research note
(`docs/research/14-structural-consumer-type-tradeoffs.md`, "A Proposal Test for Future Keiro
Improvements") gates every child plan of MasterPlan 25. For a documentation-only plan, most of
the ten questions are trivially inapplicable (no codec, no replay machinery, no migration is
introduced: Replay, Visibility, Ownership, Migration, Recovery, Performance, and Negative
proof concern code this plan does not write — recorded here as consciously inapplicable, not
skipped). Three questions bind directly. *Authority* (question 1): the authority for every
guarantee claim in the guide is the executed code, cited by `file:line`; the guide must never
promote a roadmap item, a generated comment, or a spec-level intention into a claim of
enforcement — the acceptance items 2 and 6 above are this question made mechanical.
*Compatibility direction* (question 4): wherever the guide discusses evolution, it must keep
the directions distinct exactly as the evolution guide does — new-binary-reads-old-history,
old-binary-reads-new-events during rollout, snapshot hydration, and public consumers are
different questions; the ledger must not collapse them into one "compatible/breaking" label
when describing what `diff` reports. *Completeness* (question 6, transposed to documentation):
what makes an omitted or false claim fail? The `file:line` citation discipline — a claim
without a citation is not permitted into the guide, and a citation that does not support its
claim fails the acceptance spot-check. The guide additionally documents its own
incompleteness honestly (the hole-body blind spot, the advisory-only witness), which is the
documentation analogue of the note's rule that an unprovable capability may ship only as an
explicitly opaque escape hatch, never as a checked claim.


## Idempotence and Recovery

Every step is an ordinary file edit and is safe to repeat. Re-running the citation
verification greps is read-only. If the guide is partially written, resume from the section
plan in Milestone 1 — sections are independent. If IR-1's edit goes wrong, restore with
`git checkout -- docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`
and re-apply; the edit is small and fully described in Milestone 2. If line numbers cited in
this plan have drifted by the time of implementation, update the citations in the guide to the
current tree (and note the drift in Surprises & Discoveries); the claims themselves are
anchored to named declarations (`withFoldFingerprint`, `AuditFull`, `mkEventStreamUnchecked`,
`validateTransducer`, `run (Diff ...)`) which the greps in Concrete Steps relocate. Nothing in
this plan writes outside `docs/`, so there is no build or data risk and no rollback path
beyond `git`.


## Interfaces and Dependencies

No libraries, services, types, or function signatures are added or changed; this plan only
reads code and writes Markdown. The files read as evidence:
`/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs` (sibling keiki checkout;
`validateTransducer` and its warning vocabulary),
`keiro-core/src/Keiro/EventStream/Validate.hs`, `keiro/src/Keiro/Snapshot/Codec.hs`,
`keiro/src/Keiro/Command.hs`, `keiro/src/Keiro/ReplayAudit.hs`, `keiro-dsl/app/Main.hs`,
`keiro-dsl/src/Keiro/Dsl/Diff.hs`, `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs`,
`keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs`, `keiro-dsl/src/Keiro/Dsl/Goldens.hs`, and
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`. The files written:
`docs/guides/dsl-guarantees-and-hand-written-services.md` (new),
`docs/guides/README.md` and `docs/guides/evolution-and-replayability.md` (one link each),
`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md` (framing
prose and frontmatter timestamp), and this plan file (living sections). Normative references
this plan implements sections of: `docs/research/14-structural-consumer-type-tradeoffs.md`
(guarantees G1-G6 summary, section 1's false-confidence argument, the Proposal Test) and
`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md` (framing
revision only, as assigned by
`docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md`).
ADRs cited: `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`,
`docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md`,
`docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`. The only
tool dependency is `git` (and optionally `just` for the `adr-validate` regression check);
there is no markdown link-check tooling in the repository, so link validation is the manual
procedure in Concrete Steps.
