---
id: 152
slug: prove-migrations-with-shadow-codec-comparison-and-structural-coverage-reporting
title: "Prove migrations with shadow codec comparison and structural coverage reporting"
kind: exec-plan
created_at: 2026-07-28T10:49:00Z
intention: "intention_01kym5dc4ve69sxsjtzd81pbbz"
master_plan: "docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md"
---

# Prove migrations with shadow codec comparison and structural coverage reporting

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today a team migrating an existing event-sourced service onto `keiro-dsl`'s structural
consumer-owned types has no tool that tells them whether the codec Keiro will generate
produces the same bytes — or at least the same meaning — as the hand-written Aeson codec
that wrote their history. They either eyeball JSON, or they cut over on faith. Separately,
once the opaque escape hatch exists (an "opaque external-codec type" is a declaration where
Keiro stores and round-trips a value using the consumer's own `ToJSON`/`FromJSON` instances
but makes no claim about the JSON inside it), nothing measures how much of a service's
persisted wire surface is actually structurally declared versus opaque. Years later, most
of the surface could be opaque and the `diff` gate would be theater — every review would
pass because Keiro was honestly claiming nothing.

After this plan, two things exist. First, `keiro-dsl codec compare` takes a `.keiro` spec,
a `--type` selection, and a fixture corpus directory, encodes domain values with both the
historical consumer codec and the generated structural codec, decodes the corpus with both,
and reports byte equality, semantic JSON equality (RFC 8785 canonical form), decode
differences, and missing coverage (declared union arms and optional/null branches with no
fixture). Every difference is classified as exact parity or as explicit version/upcaster
work — never "close enough". The command's own output states, verbatim, that a passing
comparison is migration evidence only and that the generated codec is the sole wire
authority after cutover. Second, `check` (and `diff`) can emit a machine-readable
structural-versus-opaque coverage report per persisted surface (aggregate events,
snapshots, queue payloads, contracts) so CI can watch drift toward opaque — "opaque creep"
— as a number, with an optional, off-by-default gate flag for operators who choose a
threshold. You can see both working by running the transcripts in Concrete Steps against
the conformance fixtures this plan adds.

This plan implements the shadow-comparison and coverage-reporting improvements from
`docs/research/14-structural-consumer-type-tradeoffs.md` (sections 1, 3, and 12, and
Experiment B) for the capability requested by
`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md` (IR-1).


## Progress

- [ ] Milestone 1: comparison engine and report model in `Keiro.Dsl.CodecCompare` with unit tests.
- [ ] Milestone 2: `keiro-dsl codec compare` CLI command, generated comparison driver, and the
      generalized Experiment B conformance fixture (historical quirky codec vs generated codec).
- [ ] Milestone 3: structural-versus-opaque coverage report in `check`/`diff`, new
      DiagnosticCodes appended, optional gate flag.
- [ ] Milestone 4: documentation — brownfield-guide shadow-comparison section, evolution-guide
      update, new coverage-policy ADR, ADR 0004 inventory amendment if a gate row was added.
- [ ] Final: Proposal Test answers recorded, ADR distillation pass, plan marked complete.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The comparison engine's semantic-equality check uses RFC 8785 canonical JSON
  bytes, obtained from aeson's own `Data.Aeson.RFC8785.encodeCanonical`, not from the
  `keiro` package.
  Rationale: The repository already standardizes on RFC 8785 canonical bytes for replay-audit
  correctness (ADR 0004: "Correctness compares RFC 8785 canonical bytes"). The implementation
  the runtime uses is `keiro/src/Keiro/ReplayDigest.hs` (`canonicalJsonBytes`), but that lives
  in the `keiro` package, and the `keiro-dsl` library deliberately does not depend on `keiro`
  (its build-depends are aeson/base/containers/megaparsec/etc. only). `canonicalJsonBytes` is
  itself a one-line wrapper over `Data.Aeson.RFC8785.encodeCanonical`, which ships in aeson
  (>= 2.2.1), already inside keiro-dsl's dependency footprint. Using the same aeson primitive
  keeps the algorithm identical to the replay audit without inverting the package layering.
  Date: 2026-07-28

- Decision: `codec compare` is split into a pure classification engine in the `keiro-dsl`
  library, a generated comparison driver module that the consumer compiles, and a thin CLI
  orchestrator — mirroring how `scaffold`/harness already work.
  Rationale: The historical codec is an arbitrary consumer `ToJSON`/`FromJSON` instance in
  the consumer's Haskell code. The `keiro-dsl` executable cannot call arbitrary Haskell at
  runtime; the only honest way to execute both codecs is generated code compiled against the
  consumer package, exactly as the conformance harness already executes fixture bindings.
  The engine (corpus loading, canonical comparison, classification, report rendering) stays
  in the library so it is unit-testable without any consumer package.
  Date: 2026-07-28

- Decision: The coverage report is reporting-first; the only rejection is behind an explicit
  opt-in flag (`--max-opaque-share`), and the default behavior never fails a build.
  Rationale: How much opacity is acceptable is an operator policy choice, not a soundness
  fact. Research note section 3 is explicit that conformance evidence must not upgrade the
  claim, and symmetrically a coverage number must not silently become a new rejection —
  that would punish honest opaque declarations and push authors toward dishonest structural
  ones. The report makes drift visible; thresholds belong to the operator. This decision is
  the seed of the new ADR in Milestone 4.
  Date: 2026-07-28

- Decision: Draft this plan against IR-1's specified generation-layer API (the
  `StructuralBinding` binding type, generated structural codecs, fixture and generator
  bindings, and the conformance-harness contract) as its hard dependency
  `docs/plans/150-implement-the-ir-1-generation-layer-bindings-api-generated-codecs-scaffold-and-conformance-harness.md`
  will land it, and require the implementer to read plan 150's landed state before writing
  any code.
  Rationale: Plan 150 (the MasterPlan's EP-7) is a hard dependency and is not yet
  implemented at drafting time. Module names and exact signatures below are therefore
  targets defined by IR-1 and the MasterPlan's integration points ("EP-7 must publish the
  API in a dedicated module with a stability note before EP-8/EP-9 begin"); the landed API
  is authoritative and this plan must be revised to match it, recording any divergence in
  this Decision Log.
  Date: 2026-07-28

- Decision: The acceptance scenario generalizes research-note Experiment B instead of using
  Mori's `DocInfo` directly.
  Rationale: Experiment B names Mori's `DocInfo` goldens, but `DocInfo` lives downstream in
  the Mori repository, and IR-1's Out of Scope section keeps Mori transducer work out of
  Keiro. The scenario's shape — a hand-written historical Aeson codec with missing-field,
  explicit-null, and unknown-field quirks plus a multi-arm tagged union — is reproduced with
  repo-local fixture types in a keiro-dsl conformance suite, preserving Experiment B's
  success criterion verbatim: differences are classified as exact parity or explicit
  version/upcaster work, nothing else.
  Date: 2026-07-28


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository is a Cabal multi-package Haskell project (see `cabal.project` at the repo
root: packages `keiro`, `keiro-core`, `keiro-migrations`, `keiro-pgmq`, `keiro-test-support`,
`jitsurei`, `keiro-dsl`). All work in this plan happens in the `keiro-dsl` package and under
`docs/`. `keiro-dsl` is a specification toolchain: you write a service description in a
`.keiro` text file, and the toolchain parses it (`keiro-dsl/src/Keiro/Dsl/Parser.hs`),
validates it (`keiro-dsl/src/Keiro/Dsl/Validate.hs`), classifies changes between two spec
versions (`keiro-dsl/src/Keiro/Dsl/Diff.hs`), and emits generated Haskell plus typed holes
(`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`) and a conformance harness
(`keiro-dsl/src/Keiro/Dsl/Harness.hs`). The CLI in `keiro-dsl/app/Main.hs` currently exposes
the subcommands `parse`, `check`, `scaffold`, `diff`, and `new` via optparse-applicative.

Terms used throughout, in plain language:

- A *structural mapped type* (from IR-1) is a consumer-owned Haskell type (record, enum, or
  tagged union) whose wire shape is declared inside the `.keiro` spec — field keys, union
  tags, presence, nullability, defaults — and whose encoder/decoder Keiro generates. A typed
  *binding* (`StructuralBinding`) converts between the consumer type and the declared shape;
  it never supplies a second JSON schema.
- An *opaque external-codec type* is the honest alternative: Keiro stores and round-trips
  the value using the consumer's own codec identity and version, and makes no claim about
  the JSON below the boundary.
- The *historical consumer codec* is whatever hand-written `ToJSON`/`FromJSON` instance
  wrote a service's existing history before migration.
- A *fixture corpus* is a directory of JSON files: real historical goldens (bytes captured
  from production or tests) and/or values produced by the declared fixture/generator
  bindings from IR-1's harness contract.
- *Semantic JSON equality* means equality of RFC 8785 canonical bytes — JSON with sorted
  object keys and normalized number/string forms, so two encodings that differ only in key
  order or whitespace compare equal, while a real difference (a missing key versus an
  explicit `null`) does not.
- *Opaque creep* is the drift failure mode where, over years, more and more of the persisted
  surface is declared opaque, so `diff`'s structural guarantees quietly cover less and less.

Hard dependency. This plan builds directly on the IR-1 generation layer delivered by
`docs/plans/150-implement-the-ir-1-generation-layer-bindings-api-generated-codecs-scaffold-and-conformance-harness.md`
(the MasterPlan's EP-7): the `StructuralBinding` API and its published module, the generated
structural codecs, the fixture and generator bindings, and the conformance-harness
architecture that compiles generated modules against consumer types (the existing pattern
is visible in the `keiro-dsl-conformance` test-suite in `keiro-dsl/keiro-dsl.cabal`, whose
`Generated.*` modules under `keiro-dsl/test/conformance/` are pinned byte-identical to
scaffold output). **Before writing any code, read plan 150 in its landed state** — its
Interfaces and Dependencies section names the real module paths and signatures — and revise
the module names and signatures in this plan to match, logging any divergence in the
Decision Log. At drafting time plan 150 is not yet implemented, so everything below that
references the binding API uses IR-1's specified semantics
(`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`,
sections "Structural mapped types", "Conformance Harness Contract").

Soft dependency. `docs/plans/151-reduce-binding-boilerplate-skeleton-scaffolds-derived-nominal-bindings-and-explain-bindings.md`
(EP-8) makes binding fixtures cheaper to author via skeleton scaffolds. If it has landed,
use its skeleton scaffolder to author this plan's conformance fixtures; if not, write the
bindings by hand — nothing here requires EP-8 to compile.

Normative sources, both checked in and both required reading:

- `docs/research/14-structural-consumer-type-tradeoffs.md`. Section 1 ("We Give Up Arbitrary
  Codec Reuse in Structural Mode") motivates and sketches the `codec compare` command,
  including its report contents (byte equality, semantic JSON equality, decode differences,
  missing coverage) and the authority rule: "Passing the comparison is migration evidence;
  the generated codec remains the authority after cutover." Section 3 ("Opaque Mode Gives Up
  Nested Compatibility Knowledge") states the rule this plan must never violate:
  "Support conformance evidence without upgrading the claim" — fixture corpora and passing
  comparisons may justify operator trust "but must not silently change an opaque diagnostic
  into a structural guarantee." Section 12 ("Existing History Makes Structural Adoption a
  Migration") defines the migration discipline the command serves: import real goldens, run
  shadow comparison, version rather than normalize silently, retain legacy decoders only at
  the version boundary. Experiment B ("Historical shadow comparison") supplies the
  acceptance scenario and its success criterion: "differences are classified as exact parity
  or explicit version/upcaster work." Its "A Proposal Test for Future Keiro Improvements"
  section defines the ten-question soundness gate answered in Validation and Acceptance.
- `docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`
  (IR-1). Its Design Principles (one wire-schema authority; bindings typed and explicit),
  Conformance Harness Contract (fixture bindings, branch and union-arm coverage), and Out of
  Scope list ("Proving that an arbitrary external `ToJSON` or `FromJSON` instance matches a
  structural declaration" is out of scope — which is exactly why `codec compare` produces
  evidence over a finite corpus, not a proof) bound this plan's claims.

Relevant local ADRs (filenames scanned in `docs/adr/`; only these are relevant):

- `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` (ADR-4).
  Defines the layered gate model, the machine-readable `DiagnosticCode` correlation between
  `check` and `diff`, the gate-inventory table, its amendment protocol ("The inventory is
  amended when a later child plan changes a gate's ownership"), and the canonical-bytes rule
  ("Correctness compares RFC 8785 canonical bytes; SHA-256 digests are review identifiers").
  This plan appends DiagnosticCodes, reuses the canonical-bytes convention, and amends the
  inventory if the optional coverage gate constitutes a new gate row (it does — see
  Milestone 4).
- `docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md` (ADR-3) is
  background for why snapshots are one of the four persisted surfaces the coverage report
  enumerates; no change to it is planned.

No existing local ADR covers shadow comparison or coverage policy; Milestone 4 creates one.
The `docs/adr/` directory is a profile-governed OKF bundle (`docs/adr/profile.dhall`,
reserved `log.md`); ADR authoring must follow the ID-allocation and strict-validation
workflow in `.claude/skills/exec-plan/ADR.md`, restated concretely in Milestone 4.
Cross-repository context: IR-1 cites Mori's originating plan
`mori://shinzui/mori/plans/171-extend-keiro-dsl-for-structural-mori-domain-contracts` and
Mori's ADR `mori://shinzui/mori/okf/adrs/concepts/ADR-6`; neither needs to be read to
implement this plan.

Documentation surfaces this plan touches: the brownfield migration guide created by
`docs/plans/145-write-the-brownfield-migration-and-transducer-modeling-guide.md` (EP-2; the
MasterPlan states EP-9 appends its command's section to that guide, and plan 145 leaves a
named anchor point for it — the `codec-compare-tooling` `appended-by` comment in
`docs/guides/brownfield-migration-and-transducer-modeling.md`, at the end of its "Shadow
comparison of old and new codecs" chapter),
and `docs/guides/evolution-and-replayability.md` (a landed guide; its "The gates, at a
glance" and "Gate coverage summary" sections are where the coverage report is mentioned).

Where the diagnostic registry lives: `keiro-dsl/src/Keiro/Dsl/Validate.hs` defines the
`DiagnosticCode` enum beginning near line 39. It is the single append-only registry shared
by `check` and `diff` (ADR 0004). New codes go at the end of the enum; never rename or
reuse an existing constructor.

Build and test commands (verified against `cabal.project`, `Justfile`, and
`keiro-dsl/keiro-dsl.cabal`): development happens inside the Nix dev shell (`nix develop`
from the repo root; `flake.nix` provides GHC 9.12 and tooling). From the repo root:
`cabal build keiro-dsl` builds the package; `cabal test keiro-dsl-test` runs the unit
suite; `cabal test keiro-dsl-conformance` (and siblings such as
`keiro-dsl-conformance-snapshot`) run the conformance suites; `just adr-validate` runs the
strict OKF check over `docs/adr`; `just verify` is the full repository gate
(process-compose check, jitsurei, `cabal build all`, tests, adr-validate).


## Plan of Work

The work proceeds in four milestones. Each is independently verifiable and the plan's story
is: first make comparison classification a pure, testable fact; then wire it to real codecs
through generated code and prove the Experiment B scenario; then make opacity measurable;
then write down the policy and teach the migration path.

### Milestone 1 — The comparison engine as a pure library

Scope: a new module `keiro-dsl/src/Keiro/Dsl/CodecCompare.hs` (exposed in
`keiro-dsl/keiro-dsl.cabal` under `exposed-modules`) that defines the report model and the
classification logic with no IO against consumer code. At the end of this milestone you can
feed the engine two lists of encode/decode results and a coverage inventory and get back a
deterministic, machine-readable report; `cabal test keiro-dsl-test` exercises it.

Define, in prose here and in Haskell there: a `CompareInput` per fixture (fixture path,
origin — historical golden or generated-from-binding — historical encoding bytes, generated
encoding bytes, historical decode outcome, generated decode outcome, and for decode
outcomes a re-encode of the decoded value so semantic decode agreement is checkable); a
`FixtureVerdict` with exactly three constructors: `ExactParity` (bytes equal),
`SemanticParity` (bytes differ, RFC 8785 canonical forms equal — report the byte
difference but classify as parity of meaning, still listed so the operator sees it), and
`RequiresVersionWork` (canonical forms differ, or decode outcomes disagree) carrying a
human explanation of the first divergent JSON path. There is deliberately no
"close enough" constructor; Experiment B's success criterion is that every difference is
parity or explicit version/upcaster work. Coverage is a separate list of
`CoverageGap` values naming each declared union arm, optional-field presence branch, and
null branch that no fixture in the corpus exercised (the declared branches come from the
resolved type-expression graph plan 149 lands, consumed here through plan 150's generation
layer; the engine takes the branch inventory as
input so it stays pure). The report renderer produces both the human transcript shown in
Concrete Steps and a JSON document (via aeson) with stable field names; the JSON top level
carries `"authority"` prose stating the migration-evidence-only framing so even
machine-consumed reports carry the claim boundary.

Semantic equality uses `Data.Aeson.RFC8785.encodeCanonical` from aeson (see Decision Log:
same algorithm as the runtime's `Keiro.ReplayDigest.canonicalJsonBytes`, without a
package-layering inversion; raise keiro-dsl's aeson lower bound to `>=2.2.1` if the module
is not present at the current `>=2.2` bound). Unit tests in `keiro-dsl/test/` cover: key
order and whitespace differences classify as `SemanticParity`; omitted-key versus
explicit-`null` classifies as `RequiresVersionWork`; a decode disagreement (one codec
rejects, the other accepts) classifies as `RequiresVersionWork`; an uncovered union arm
produces a `CoverageGap`; and the JSON report round-trips.

### Milestone 2 — The `codec compare` command and the Experiment B fixture

Scope: the CLI subcommand, the generated comparison driver, and the conformance proof. At
the end of this milestone the transcripts in Concrete Steps work against a repo-local
fixture, and `cabal test keiro-dsl-conformance-codec-compare` passes.

The command is `keiro-dsl codec compare SPEC --type NAME --fixtures DIR
[--report PATH] [--driver-out PATH]`, added to the subcommand tree in
`keiro-dsl/app/Main.hs` as a two-level command (`codec` group with `compare` under it, so
future codec tooling has a home). Because the historical codec is arbitrary consumer
Haskell, the executable cannot run it directly; the command therefore has two halves.
The spec-side half (runnable by the CLI alone) parses and validates the spec, resolves
`--type` to a structural mapped declaration (rejecting opaque declarations with a clear
message — comparing against an opaque declaration is meaningless because Keiro claims
nothing to compare against, and silently accepting it would be the forbidden upgrade path),
scans the fixture corpus, computes the declared-branch inventory, and reports coverage gaps
that need no codec execution. The execution half is a generated create-once comparison
driver module (emitted like scaffold output, named per plan 150's generated-module
conventions, e.g. `Generated.<Service>.<Type>.CodecCompare`) that imports the consumer type,
its historical instances, the generated structural codec, and the `StructuralBinding`, runs
every fixture through both codecs, and feeds `Keiro.Dsl.CodecCompare` to print the report
and exit non-zero when any verdict is `RequiresVersionWork` or any `CoverageGap` exists.
How the driver names the historical codec follows plan 150's landed convention for naming
consumer symbols (binding-style declaration or driver parameter); read the landed state and
match it. In this repository the driver runs inside a conformance test-suite; downstream
consumers compile the emitted driver in their own package, exactly as they compile scaffold
output.

CRITICAL FRAMING, stated here and emitted by the command itself in both human and JSON
output: a passing comparison is MIGRATION EVIDENCE ONLY. The generated structural codec is
the sole wire authority after cutover. The command must never be wired as a runtime
fallback path, must never select which codec runs, and must never upgrade an opaque
declaration to structural (research note section 3: conformance evidence must not upgrade
the claim). The driver imports both codecs solely to compare them; nothing it emits is
importable by production code paths, and the generated module carries a header comment
saying so.

The acceptance scenario generalizes Experiment B (see Decision Log). Add a new test-suite
`keiro-dsl-conformance-codec-compare` to `keiro-dsl/keiro-dsl.cabal` (modeled on the
existing `keiro-dsl-conformance` stanza) with hand-owned fixture code under
`keiro-dsl/test/conformance-codec-compare/`: a record type with an optional field, a
five-arm tagged union (mirroring IR-1's `DocLocation` example), and a deliberately quirky
hand-written historical Aeson codec that (a) omits the optional key when `Nothing` rather
than emitting `null`, (b) tolerates and drops unknown fields on decode, and (c) uses
constructor-spelled union tags that differ from the spec's declared wire tags for exactly
one arm. A `.keiro` spec under the same directory declares the structural shape matching
the historical wire contract for everything except that one arm and the null policy. The
fixture corpus contains historical goldens covering missing fields, explicit nulls,
unknown fields, and every union arm. The suite asserts: the arms and fields where the
historical contract was faithfully transcribed report `ExactParity` or `SemanticParity`;
the omitted-versus-null field and the renamed-tag arm report `RequiresVersionWork` with
the divergent path named; removing one arm's fixture from the corpus produces a
`CoverageGap` and a non-zero exit; and the report never contains any third category. This
is also the plan's negative proof (Proposal Test question 10): the suite pins a corpus
where the historical codec genuinely differs and asserts the command refuses to call it
parity — if classification were incomplete or lenient, this test fails.

### Milestone 3 — Structural-versus-opaque coverage reporting

Scope: per-surface coverage accounting in `check` and `diff`, new DiagnosticCodes, an
optional gate flag. At the end of this milestone
`keiro-dsl check SPEC --coverage-report PATH` writes a JSON document CI can track, and the
default behavior of `check`/`diff` on any existing spec is unchanged.

Walk the resolved type-expression graph (plan 149's graph, `Keiro.Dsl.TypeGraph`; IR-1
requires one total
traversal registry, so extend that registry rather than writing an ad hoc walk — IR-1:
"All consumers of the graph must use one total traversal registry so adding a new
type-expression constructor cannot silently omit a subsystem"). For each persisted surface
— aggregate events, snapshots, queue payloads, and contracts, keyed per stream/root —
count declared types and fields (including nested mapped types, and counting an explicit
`Json` leaf inside a structural declaration as opaque at that leaf) under each mode:
structural, opaque, and the pre-IR-1 primitive scalars (which count as structural — they
are fully declared). Emit per-surface and per-root counts plus an `opaqueShare` ratio, and
a repo-level rollup, as JSON with stable field names. Add `--coverage-report PATH` to both
`check` and `diff` in `keiro-dsl/app/Main.hs` (on `diff`, the report additionally carries
the previous ref's numbers and the delta, so CI can alert on drift direction, not just
level). Also print a one-line human summary per surface when the flag is given.

This is reporting, NOT a new rejection. Policy thresholds are an operator choice. Add an
optional `--max-opaque-share RATIO` flag (accepted only together with `--coverage-report`);
only when the operator passes it does an exceeded ratio become an Error diagnostic and a
non-zero exit. The default emits Advisory-severity diagnostics only.

Append to the end of the `DiagnosticCode` enum in `keiro-dsl/src/Keiro/Dsl/Validate.hs`
(the shared append-only registry beginning near line 39; per ADR 0004, tests and tooling
match on codes, not prose): `CoverageOpaqueSurface` (advisory: this persisted root contains
opaque declarations; carries the counts), `CoverageOpaqueShareIncreased` (advisory, diff
only: the opaque share of a surface grew since the compared ref), and
`CoverageOpaqueGateExceeded` (error, emitted only under `--max-opaque-share`). For the
comparison command, also append `CodecCompareDifference` (a fixture classified as
`RequiresVersionWork`) and `CodecCompareCoverageGap` (a declared branch with no fixture) so
the compare report's machine consumers key on registry codes too. Do not rename or reuse
any existing constructor. Unit tests pin each new code's trigger and severity, and pin that
a spec with zero opaque declarations produces a report with zero opaque counts and no
advisory.

### Milestone 4 — Documentation and the coverage-policy ADR

Scope: teach the migration path and record the policy decision durably. At the end of this
milestone the brownfield guide's shadow-comparison anchor is filled, the evolution guide
names both new capabilities, a new ADR records the reporting-first coverage policy, ADR
0004's inventory is amended, and `just adr-validate` passes.

Append the shadow-comparison section to the brownfield migration guide created by
`docs/plans/145-write-the-brownfield-migration-and-transducer-modeling-guide.md` at the
named anchor point it leaves for EP-9 — the `codec-compare-tooling` `appended-by` comment
in `docs/guides/brownfield-migration-and-transducer-modeling.md`, at the end of its
"Shadow comparison of old and new codecs" chapter (if plan 145 has not landed yet, do not block — add the
section to a new appendix file only as a last resort and record the deviation in the
Decision Log, since the MasterPlan sequences EP-2 well before EP-9). The section walks the
migration discipline of research-note section 12 with the real command: capture goldens
first, declare the shape from the historical wire contract, run `codec compare`, then
either cut over on parity or write an explicit version bump and upcaster for every
`RequiresVersionWork` fixture — never normalize silently, and retain the legacy decoder
only as upcaster input at the version boundary, never as a second authority.

Update `docs/guides/evolution-and-replayability.md`: in "The gates, at a glance" and "Gate
coverage summary", add the coverage report as an observability aid (explicitly labeled as
reporting, not a gate, unless the operator opts into `--max-opaque-share`), and mention
`codec compare` in the persisted-payloads discussion as the migration-evidence tool.

Create the new ADR recording the structural-versus-opaque coverage policy: reporting-first;
opaque is honest and permitted; thresholds are operator policy via an explicit flag; a
passing shadow comparison never upgrades a claim; the comparison command is migration
evidence only and never a runtime authority. Follow `.claude/skills/exec-plan/ADR.md`
exactly: allocate the docId with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`
(do not guess or count files), write the record at the bundle root with the required
frontmatter (`type: Architecture Decision Record`, `title`, one-sentence `description`,
`docId`, `status`, `date`, `timestamp`), maintain the reserved `docs/adr/log.md` with
`okf log add`, and run the strict validation shown in Concrete Steps.

Amend ADR 0004's gate-inventory table: the optional `--max-opaque-share` gate is a new gate
row (change class "opaque-share drift beyond declared policy"; single-spec `check` emits
the report and, under the flag, `CoverageOpaqueGateExceeded`; cross-spec `diff` adds the
delta; no runtime boundary — the runtime is unaffected). Update ADR 0004's `timestamp`,
add a log entry, and re-run strict validation. Follow conventional commits for every
commit (e.g. `feat(dsl): add codec compare shadow comparison`, `docs(adr): record
structural-versus-opaque coverage policy`); commit directly to the current branch.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`, inside the
Nix dev shell (`nix develop`). Update this section with actual transcripts as work lands.

Read the dependency's landed state first:

```bash
cat docs/plans/150-implement-the-ir-1-generation-layer-bindings-api-generated-codecs-scaffold-and-conformance-harness.md
```

Confirm its Progress section shows the `StructuralBinding` API, generated codecs, and
fixture bindings landed, and note the real module paths from its Interfaces and
Dependencies section. If plan 150 is not complete, stop: this plan's hard dependency is
unmet.

Build and unit-test after each milestone:

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test
```

Expected tail of a passing unit run:

```text
Finished in ... seconds
... examples, 0 failures
```

Milestone 2's command, against the conformance fixture (paths are targets; keep them in
sync with what you create):

```bash
cabal run keiro-dsl -- codec compare \
  keiro-dsl/test/conformance-codec-compare/docstore.keiro \
  --type DocRef \
  --fixtures keiro-dsl/test/conformance-codec-compare/fixtures/doc-ref \
  --report /tmp/doc-ref-compare.json
```

Expected output shape (values illustrative; the framing lines are mandatory and verbatim
in intent):

```text
codec compare: DocRef (structural, canonical-type "keiro.conformance.DocRef.v1")
corpus: 12 fixtures (9 historical goldens, 3 from fixture bindings)
  byte equality:     9/12
  semantic equality: 10/12 (RFC 8785 canonical form)
  decode agreement:  11/12
semantic parity (bytes differ, meaning equal): 1 fixture
  fixtures/doc-ref/key-order.json — object key order only
requires explicit version/upcaster work: 2 fixtures  [CodecCompareDifference]
  fixtures/doc-ref/legacy-missing-description.json
    historical encoder omits "description" when absent; generated codec emits null
  fixtures/doc-ref/arm-canonical.json
    union tag "Canonical" (historical) vs declared wire tag "canonical"
coverage gaps: 1  [CodecCompareCoverageGap]
  union DocLocation arm "loc_url": no fixture exercises this arm
result: NOT PARITY — 2 differences, 1 coverage gap
This comparison is MIGRATION EVIDENCE ONLY. After cutover the generated structural
codec is the sole wire authority. This command is never a runtime fallback and never
upgrades an opaque declaration to structural. Resolve each difference with an explicit
version bump and upcaster, or correct the declaration to match the historical wire
contract; "close enough" is not an outcome.
```

The command exits `1` on that transcript (differences or gaps present) and `0` only when
every fixture is `ExactParity`/`SemanticParity` and no coverage gap exists; on the passing
case the same authority framing block still prints. `/tmp/doc-ref-compare.json` contains
the machine report with an `"authority"` field carrying the same statement.

Run the Experiment B conformance suite:

```bash
cabal test keiro-dsl-conformance-codec-compare
```

Expected: the suite passes, meaning the quirky-historical-codec scenario produced exactly
the classifications described in Milestone 2 — including the negative-proof assertions
that the two genuine differences were refused parity.

Milestone 3's coverage report:

```bash
cabal run keiro-dsl -- check \
  keiro-dsl/test/conformance-codec-compare/docstore.keiro \
  --coverage-report /tmp/coverage.json
```

Expected human summary (shape, not exact numbers):

```text
structural/opaque coverage (reporting only; thresholds are operator policy):
  aggregate-events docstore/Doc: 5 types (4 structural, 1 opaque), 21 fields (19/2), opaque share 0.10
  snapshots        docstore/Doc: 2 types (2 structural, 0 opaque), opaque share 0.00
coverage report written to /tmp/coverage.json
```

And the JSON document has stable keys: top-level `spec`, `surfaces` (map of surface kind to
per-root entries with `structural`/`opaque` count objects and `opaqueShare`), and `rollup`.
With `--max-opaque-share 0.05` the same invocation exits non-zero and prints a
`CoverageOpaqueGateExceeded` error naming the offending root; without the flag it never
fails. On `diff`, the same flag pair adds `previous`, `delta`, and (when share grew)
`CoverageOpaqueShareIncreased` advisories.

Milestone 4's ADR workflow:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
# write docs/adr/NNNN-<slug>.md using the returned docId; then:
okf log add docs/adr --profile docs/adr/profile.dhall   # consult okf log add --help for exact form
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just adr-validate
```

Expected: validation reports no deviations. Finish with the repository gate:

```bash
just verify
```


## Validation and Acceptance

Acceptance is behavioral. The plan is done when all of the following are observable:

1. Running the `codec compare` transcript in Concrete Steps against the conformance fixture
   produces the report shown: byte, semantic, and decode tallies; each difference named
   with its divergent JSON path; every fixture classified as exact parity, semantic parity,
   or requires-version-work; coverage gaps listed per declared branch; the mandatory
   authority framing printed; exit code `1` because differences exist. Deleting the two
   quirky behaviors from the historical codec and re-running yields `0` with the framing
   still printed.
2. `cabal test keiro-dsl-test` and `cabal test keiro-dsl-conformance-codec-compare` pass,
   and the latter fails if you weaken classification (e.g. temporarily make
   omitted-key-versus-null compare equal) — run that mutation once, observe the failure,
   revert.
3. The coverage-report transcript works on the fixture spec; the JSON is stable and
   machine-readable; the default run never exits non-zero because of coverage; with
   `--max-opaque-share` below the fixture's actual share it exits non-zero with
   `CoverageOpaqueGateExceeded`.
4. `keiro-dsl check`/`diff` behavior on existing specs without the new flags is
   byte-identical to before (pin with the existing test suites; `cabal test
   keiro-dsl-test` includes the diff fixtures).
5. The brownfield guide contains the shadow-comparison section at plan 145's anchor, the
   evolution guide names both capabilities, the new ADR exists with an OKF-allocated docId,
   `docs/adr/log.md` is current, ADR 0004's inventory has the new gate row, and
   `just adr-validate` and `just verify` pass.

Soundness gate — the ten-question Proposal Test from
`docs/research/14-structural-consumer-type-tradeoffs.md` ("A Proposal Test for Future Keiro
Improvements"), answered for this plan. Questions 1, 7, and 10 are the load-bearing ones
and are answered in depth; do not mark this plan complete until each answer is verified
against the landed code.

1. **Authority (in depth).** The `.keiro` spec owns the wire schema and the generated
   structural codec from plan 150 is the executed codec — before, during, and after this
   plan. `codec compare` adds no authority: it is a read-only comparator that executes both
   codecs side by side in a generated driver whose output is a report, never a value used
   by production code. The comparison must never become a second authority, in any of the
   ways that could sneak in: the driver module is create-once, documented as
   non-production, and exports nothing the scaffold's production modules import; the
   command never selects which codec runs at runtime and has no "fallback to historical on
   mismatch" mode; a passing report changes no spec, no diagnostic, and no generated code —
   in particular it never flips an opaque declaration to structural or suppresses an opaque
   diagnostic (research note section 3). The command refuses `--type` selections that
   resolve to opaque declarations rather than "helpfully" comparing them, because
   accepting them is the first step of the silent-upgrade path. Verification: code review
   of the driver's import graph plus the conformance suite's assertion that an opaque
   `--type` selection is rejected with a message naming this rule.
2. **Replay.** Unaffected. This plan generates no events, edges, or registers; replay
   semantics are exactly plan 150's. The coverage walk is a read-only traversal of the
   resolved graph.
3. **Visibility.** No new Keiki claims. Neither the comparator nor the coverage report adds
   guard or update syntax; nothing here is presented as solver-visible.
4. **Compatibility direction.** The compare report distinguishes encode differences (what
   the new codec would write) from decode differences over the historical corpus (whether
   the new binary reads old bytes), which is the private-history direction; the coverage
   report is keyed per surface (events, snapshots, queues, contracts) so opacity is never
   averaged across surfaces with different compatibility questions.
5. **Ownership.** Private and public surfaces stay separately owned; the coverage report
   reports them as separate surface kinds and the comparator operates on one declared type
   at a time without bridging contracts.
6. **Completeness.** The coverage walk and the compare branch inventory both hang off the
   single total traversal registry IR-1 mandates for the resolved type graph, so a new
   type-expression constructor that misses them is a compile error or registry-totality
   test failure, not a silent omission. The new DiagnosticCodes live in the shared
   append-only registry with pinned tests.
7. **Migration (in depth).** This plan is the migration-proof machinery for IR-1
   adoption, so the answer must be concrete: existing bytes are proven compatible only by
   evidence over a real corpus — historical goldens captured before the declaration was
   written (research note section 12: derive the declaration from the historical wire
   contract, not from Haskell spelling) plus generator-driven values covering every
   declared arm and branch, with coverage gaps reported as first-class failures so a
   passing run cannot rest on an unexercised arm. Tags and defaults are compared through
   actual encode/decode execution of both codecs, not by inspecting declarations. When the
   corpus shows any difference, the only sanctioned path is Experiment B's: an explicit
   version bump and upcaster for each difference, with the legacy decoder retained solely
   as upcaster input at the version boundary. The command's report and the brownfield
   guide both state this; "close enough" is unrepresentable in the verdict type. And the
   limits are honest: a corpus is evidence, not proof (IR-1's Out of Scope: proving an
   arbitrary instance matches a declaration is out of scope), which is exactly why passing
   comparison never upgrades any claim.
8. **Recovery.** The command and the report are read-only over specs and fixtures; a
   half-finished run leaves no state beyond a partial report file, and re-running
   overwrites it. The generated driver is create-once and re-emitting it is idempotent
   under the scaffolder's existing no-overwrite rules. Nothing here touches runtime
   deployment, so the old release path is untouched.
9. **Performance.** The comparator runs at development/CI time, not on any hot path; corpus
   size bounds its cost linearly. No production overhead is introduced, so no benchmark
   gate is required; if a consumer's corpus grows large, the report's per-fixture cost is
   the two codec executions they were going to need evidence for anyway.
10. **Negative proof (in depth).** The Experiment B conformance suite is the negative
    proof, and it must be present before the plan is accepted: a fixture corpus where the
    historical codec genuinely differs (omitted-key-versus-null on one field; a wire tag
    that differs on one union arm) and the suite asserts the command classifies both as
    `RequiresVersionWork`, names the divergent paths, exits non-zero, and never emits
    parity for them. A second negative asserts an uncovered declared arm yields
    `CodecCompareCoverageGap` and non-zero exit, so a green run cannot be produced by
    starving the corpus. A third asserts the opaque-selection refusal (question 1). The
    mutation check in acceptance item 2 (weaken canonical comparison, watch the suite
    fail) demonstrates the suite actually guards the classification rather than the
    transcript text. If any of these can be made to pass while the machinery is
    incomplete, the guarantee is not landed.


## Idempotence and Recovery

Every step is safe to repeat. `codec compare` reads specs and fixtures and writes only its
report file (and, with `--driver-out`, the create-once driver, which follows the
scaffolder's existing rule of never overwriting an existing file — re-running reports
rather than clobbers). `check --coverage-report` overwrites its output file
deterministically. Test suites are hermetic. The ADR steps are the only ones with ordering
sensitivity: allocate the docId with `okf id next` immediately before writing the file, and
if validation fails after a partial edit, fix frontmatter and re-run `okf validate` — no
state is corrupted by retries. If a milestone stalls, earlier milestones remain
independently valuable and shippable (the engine without the CLI is still a tested
library; the compare command without coverage reporting is still complete evidence
tooling); record the stopping point in Progress.


## Interfaces and Dependencies

Dependencies: the `keiro-dsl` library's existing footprint (aeson `>=2.2.1` for
`Data.Aeson.RFC8785` — raise the lower bound in `keiro-dsl/keiro-dsl.cabal` from `>=2.2`
if needed; megaparsec, containers, text, filepath, directory as already declared) and
optparse-applicative in the executable. No dependency on the `keiro` package is added to
the `keiro-dsl` library or executable; the new conformance suite may depend on `keiro`
and `keiki` like the existing `keiro-dsl-conformance` suite does. From plan 150 (read its
landed Interfaces section for authoritative names): the `StructuralBinding` API module
(`Keiro.Codec.Structural`), the generated structural codec entry points, and the
fixture/generator binding conventions (`FixtureCases`); and from plan 149 (consumed via
plan 150): the resolved type-expression graph (`Keiro.Dsl.TypeGraph`) and its total
traversal registry.

At the end of Milestone 1, `Keiro.Dsl.CodecCompare` (new module,
`keiro-dsl/src/Keiro/Dsl/CodecCompare.hs`) exposes at minimum:

```haskell
data FixtureOrigin = HistoricalGolden | FromBinding
data DecodeOutcome = Decoded Value | DecodeFailed Text
data CompareInput = CompareInput
  { fixturePath :: FilePath
  , origin :: FixtureOrigin
  , historicalBytes :: ByteString
  , generatedBytes :: ByteString
  , historicalDecode :: DecodeOutcome
  , generatedDecode :: DecodeOutcome
  }
data FixtureVerdict = ExactParity | SemanticParity | RequiresVersionWork Text
data CoverageGap -- declared branch (union arm / presence / null) with no fixture
data CompareReport -- verdicts, gaps, tallies, authority framing; ToJSON with stable keys
classifyFixture :: CompareInput -> FixtureVerdict
compareReport :: [CompareInput] -> [DeclaredBranch] -> CompareReport
renderCompareReport :: CompareReport -> Text  -- the human transcript
```

(`DeclaredBranch` is the branch-inventory type computed from plan 149's resolved graph;
adopt the landed graph's naming.) At the end of Milestone 2, `keiro-dsl/app/Main.hs` has
the `codec compare` subcommand and the scaffolding side emits the generated driver module;
the new test-suite `keiro-dsl-conformance-codec-compare` exists in
`keiro-dsl/keiro-dsl.cabal`. At the end of Milestone 3, `Keiro.Dsl.Validate` carries the
five appended `DiagnosticCode` constructors (`CoverageOpaqueSurface`,
`CoverageOpaqueShareIncreased`, `CoverageOpaqueGateExceeded`, `CodecCompareDifference`,
`CodecCompareCoverageGap`), and the coverage walk lives with the graph traversal (either a
new `Keiro.Dsl.Coverage` module or inside the module plan 149 gives the resolved graph —
choose whichever keeps the traversal-registry totality check covering it, and record the
choice in the Decision Log). At the end of Milestone 4, the new ADR exists under
`docs/adr/` with its OKF-allocated docId, and ADR 0004 carries the amended inventory row.


---

Revision note: Aligned cross-plan references during MasterPlan 25 consistency review, 2026-07-28.
