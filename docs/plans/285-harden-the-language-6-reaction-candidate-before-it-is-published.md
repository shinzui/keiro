---
id: 285
slug: harden-the-language-6-reaction-candidate-before-it-is-published
title: "Harden the Language 6 reaction candidate before it is published"
kind: exec-plan
created_at: 2026-09-16T18:25:28Z
intention: "intention_01m2nqd9hre9gbhw37aagtf066"
master_plan: "docs/masterplans/43-address-the-rev-17-keiro-0-17-0-0-release-readiness-findings.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-16T18:25:28Z
---

# Harden the Language 6 reaction candidate before it is published

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro DSL Language 6 is an unpublished candidate that adds first-class process reactions:
a process declares typed inputs, per-input `on` blocks, an optional saga advance, follow-up
dispatches, and typed timers, and `keiro-dsl scaffold` generates the whole reactive process
manager. Review REV-17 (`docs/reviews/keiro-0-17-release-readiness.md`) found six defects in
that candidate surface. None blocks the 0.17.0.0 tag, because a candidate may be amended in
place, but every one of them becomes frozen contract the moment a package containing
Language 6 is published or an external consumer scaffolds a reaction service. This plan fixes
them while the candidate is still amendable.

After this plan, a service author can see the following. Two reaction timers whose correlation
ids differ only in non-ASCII characters get two distinct timer ids, so `once` scheduling,
`rearm`, and `cancel` never act on another correlation's row. A `keiro-dsl diff --format json`
report for a reaction that says "drain before deploy" carries `drain-required` in its
`rollout` array, and a removed timer or a decreased reaction version is reported on the
persisted-identity surface, the same way a changed timer id prefix already is. Editing the
operator dead-letter message or the retry ceiling under `timers max-attempts` produces only
the `ProcessTimerCeilingChanged` advisory and never the breaking
`ProcessReactionFingerprintChangedWithoutVersionBump`. The generated harness reports the same
`reactionOwnership` value that `keiro-dsl check` computed. Library callers that ask for the
process-reaction ledger rows of a service whose type graph does not resolve get an `Either`,
not a crash. And `keiro-dsl new process` writes a skeleton on the published stable language,
matching what the user reference tells new services to do.

Everything here leaves the published Languages 1 through 5 byte-identical in generated output.
That is verified, not assumed: `just corpus-regen` must change only the two candidate corpora.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: reaction template derives timer and fired-event ids from length-prefixed UTF-8 fields; hand-written expectations in `keiro-dsl/test/conformance-process-timers/Main.hs` updated; non-ASCII collision vector pinned in `keiro-dsl/test/Main.hs`.
- [ ] M1: `just corpus-regen` run; only `keiro-dsl/test/conformance-process-timers` and `keiro-dsl/test/conformance-process-reactions` changed; `just process-reaction-proof` green.
- [ ] M2: reaction advisory codes carry `RolloutDrainRequired`; `ProcessTimerRemoved`, `ProcessReactionVersionDecreased`, and `ProcessReactionFingerprintChangedWithoutVersionBump` use the persisted-identity vector; JSON report tests added.
- [ ] M3: reaction fingerprint computed from a frozen canonical encoding that excludes operator text; golden pinned; ceiling test asserts exactly `ProcessTimerCeilingChanged`; whitespace-only rewrites still produce no change.
- [ ] M4: harness `reactionOwnership` follows the checker; `processReactionRowsForService` and `processReactionSnapshots` return `Either`; `keiro-dsl new` skeletons target the stable language.
- [ ] M5: `keiro-dsl/CHANGELOG.md`, `docs/user/typed-spec-toolchain.md`, and `docs/user/deploy-ordering.md` updated; full gate green; ADR-24 amended.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Fix the reaction template's timer identity now, while Language 6 is a candidate,
  and leave the legacy process template (`emitProcessGen` in
  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`) untouched.
  Rationale: The legacy template's `namedUuid` is emitted into frozen Language 4 and 5 output;
  its ids are live replay identity in deployed services and cannot move without a migration
  story (ADR-24). The reaction template is unpublished and its corpora may be amended in place
  (ADR-16), so this is the only window in which the derivation can be corrected for free.
  Date: 2026-09-16
- Decision: Derive reaction timer ids and fired-event ids from length-prefixed UTF-8 fields
  (the declared prefix, then the correlation id), not from the UTF-8 bytes of the bare
  concatenation.
  Rationale: The bare concatenation would satisfy ADR-24's byte rule but keeps the aliasing
  hazard where prefix `a:` with correlation `b:c` equals prefix `a:b:` with correlation `c`.
  The runtime's own reaction identity (`deterministicReactionCommandId` in
  `keiro/src/Keiro/ProcessManager/Reaction.hs`) already uses decimal-length-prefixed fields,
  and `Keiro.Inbox.Delegated.delegatedEventId` does the same, so generated code follows the
  runtime's established recipe. The `.keiro` syntax `id uuidv5 "<prefix>" <> correlationId`
  is unchanged; the user reference gains one sentence stating the byte recipe.
  Date: 2026-09-16
- Decision: Base the reaction fingerprint on a frozen canonical encoding of the semantic
  surface rather than on `renderReactionSurface` output, and exclude the timer policy's
  dead-letter text and ceiling.
  Rationale: ADR-18 states that persisted pre-hash bytes come only from
  `Keiro.Dsl.CanonicalEncoding` and that presentation pretty printing may evolve independently;
  the current fingerprint would move every stored ledger value on any renderer change. The
  ceiling and dead-letter text are operator policy with their own advisory
  (`ProcessTimerCeilingChanged`), not reaction semantics.
  Date: 2026-09-16
- Decision: `keiro-dsl new <kind>` skeletons target the published stable language while a
  candidate exists.
  Rationale: `docs/user/typed-spec-toolchain.md` tells released-only services to remain on
  Language 5 until the candidate is published; a tool that writes `language keiro-dsl 6` into
  every new file contradicts that guidance and silently opts new users into an amendable
  contract. Candidate-only skeleton content, if any, must be opt-in.
  Date: 2026-09-16


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

The repository is a Cabal multi-package workspace. `keiro` is the runtime library;
`keiro-dsl` is the `.keiro` specification toolchain (parser, checker, `diff`, `scaffold`,
harness generator). Run everything from the repository root
`/Users/shinzui/Keikaku/bokuno/keiro` unless a step says otherwise. The task runner is
`just`; `just --list` shows the recipes named below.

A "language version" is the number after `language keiro-dsl` on the first line of a
`.keiro` file. The registry in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` lists versions 1
through 5 as `PublishedLanguage` and version 6 as `Candidate CandidateLanguage`.
`currentAuthoringLanguageVersion` (line 358 of that file) returns the single candidate when one
exists and otherwise `currentStableLanguageVersion`. A "candidate" is registered but
unpublished: its syntax, generated output, and fixtures may still be amended in place. A
"conformance corpus" is a directory under `keiro-dsl/test/` named `conformance-<name>` that
holds a committed scaffold of one fixture plus a hand-written test suite; the two candidate
corpora that matter here are `keiro-dsl/test/conformance-process-reactions` (fixture
`keiro-dsl/test/fixtures/process-reactions.keiro`) and
`keiro-dsl/test/conformance-process-timers` (fixture
`keiro-dsl/test/fixtures/process-timers.keiro`). `just corpus-regen` runs
`cabal run -v0 keiro-dsl-corpus-regen -- regenerate`, which discovers every corpus from the
committed `keiro-dsl-ledger.context.<context>.txt` files and re-scaffolds each; the same tool's
`check` mode is what `just verify` runs, and it fails if regeneration changes any tracked file.
The regenerate mode accepts `--only <corpus-dir>` to restrict itself.

The reaction template is `emitReactionProcessGen` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`
(it begins at line 5581 at the reviewed commit). It emits the generated `Process.hs` for a
process whose body is `ReactionProcessBody`. Its `renderFireTimer` local (around line 5771)
appends the helper

```haskell
namedUuid :: Text -> UUID
namedUuid value = UUID.V5.generateNamed UUID.V5.namespaceURL (map (fromIntegral . fromEnum) (T.unpack value))
```

and its `timerIdExpression` local (line 5785) renders every timer id as
`TimerId (namedUuid ("<prefix>" <> correlation))`; `renderTimerFire` (line 5795) renders the
fired-event id the same way with the `fired-event-id` prefix. The `map (fromIntegral .
fromEnum)` truncates every character to its code point modulo 256, so two correlation ids that
differ only in characters congruent modulo 256 hash to the same id. The legacy template
`emitProcessGen` (line 6021) emits the same helper at line 6092 and uses it at 6067; that
template is frozen published output and must not be edited by this plan. The runtime helper
`Keiro.DeterministicId.identitySeedBytes :: Text -> [Word8]` (exported from
`keiro/src/Keiro/DeterministicId.hs`, and `Keiro.DeterministicId` is an exposed module of the
`keiro` library) returns the UTF-8 bytes of a text in the shape `Data.UUID.V5.generateNamed`
expects. The runtime's reaction dispatch identity, `deterministicReactionCommandId` in
`keiro/src/Keiro/ProcessManager/Reaction.hs` (line 659), encodes each field as its decimal
UTF-8 byte length, a colon, and the bytes, then concatenates. The generated corpus currently
reads `TimerId (namedUuid ("incident-escalation-timer:" <> correlationId))` at line 59 of
`keiro-dsl/test/conformance-process-timers/Generated/ProcessTimers/IncidentTimers/Process.hs`,
and the hand-written suite `keiro-dsl/test/conformance-process-timers/Main.hs` recomputes the
same id at `expectedEscalationTimerId` (line 180) with the same truncating expression.

Diff classification lives in `keiro-dsl/src/Keiro/Dsl/Diff.hs`. Every finding is classified
by a `CompatibilityVector` (defined around line 137): six `SurfaceVerdict` values for the
surfaces `PrivateHistoryRead`, `OldBinaryReadNewEvents`, `SnapshotHydration`,
`PublicConsumer`, `PersistedIdentity`, `ConsumerBuild`, plus a `Set RolloutConstraint` whose
constructors are `RolloutStopTheWorld`, `RolloutWorkersFirst`, `RolloutDrainRequired`,
`RolloutProducerLast`, and `RolloutProducerFirst`. The function that maps a `DiagnosticCode`
to its vector is the guard chain that ends at line 426 with `| otherwise = case
(.contextOriginalLabel) context of ...`; codes not named explicitly fall to that generic
branch. `ProcessDecideSurfaceChanged` is mapped at line 406 to
`replaceRollout (Set.singleton RolloutDrainRequired) compatibleVector`, and the
`identityCodes` list at line 447 (mapped to `persistedIdentityBreakingVector` at line 392)
contains `ProcessTimerIdentityChanged` but not the three new breaking reaction codes. The
reaction and timer findings themselves are emitted around lines 2957 to 3035 (`ProcessReactionRemoved`
2969, `ProcessTimerRemoved` 2973, `ProcessTimerCeilingChanged` 2975, `ProcessReactionVersionDecreased`
2988, `ProcessReactionFingerprintChangedWithoutVersionBump` 2990, `ProcessReactionArmsReordered`
3007, `ProcessReactionGuardChanged` 3019, `ProcessReactionFanOutChanged` 3022 and 3026,
`ProcessTimerIdentityChanged` 3032). `keiro-dsl/src/Keiro/Dsl/DiffReport.hs` renders the
vector's rollout set as the JSON `rollout` array (line 272) and derives remedies in
`remediationFor` (line 275), where `firstRollout` (line 325) turns a rollout constraint into
`RemedyDeploymentOrder`; a finding with an empty rollout set falls to `RemedyRunConformance`.

The reaction fingerprint is `processReactionFingerprintFrom` in
`keiro-dsl/src/Keiro/Dsl/ProcessReaction.hs` (line 369): SHA-256 over
`T.unlines (drop 1 (T.lines (renderReactionSurface reaction)))`, where
`renderReactionSurface` (`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` line 49) pretty-prints
`docReactionBody` (line 705), which includes `docTimerPolicy`, rendered at line 760 as
`timers max-attempts <n> dead-letter "<text>"`. `checkProcessReaction` (same module, the
function whose body spans lines 100 to 137) sets `verification` to `generated-declarative`
when no hole obligations exist and `custom-unverified` otherwise, and stores the fingerprint
in the `CheckedProcessReaction` record. `Diff.hs` imports `processReactionFingerprintFrom`
directly. The frozen encoders that ADR-18 designates for persisted pre-hash bytes are in
`keiro-dsl/src/Keiro/Dsl/CanonicalEncoding.hs`, which exports `canonicalExpr`,
`canonicalTransition`, `canonicalDomainOutcomeTypes`, `canonicalTransitionOutcome`, and
`foldFingerprint128`.

The harness generator `keiro-dsl/src/Keiro/Dsl/Harness.hs` renders process facts in
`processHarnessFactValues :: ProcessNode -> [(Text, Text)]` (line 479); the reaction branch
hard-codes `("reactionOwnership", "generated-declarative")` at line 485. The callers that
have a `CheckedService` in scope are `harnessForService` (line 71) and
`harnessForCheckedWithGoldens` (line 91); `checkedTypeGraph`, `checkedLanguageContract`, and
`checkedSpec` are already imported at line 65.

`processReactionRowsForService :: CheckedService -> [ProcessReactionRecordRow]` in
`keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` (line 328) and
`processReactionSnapshots :: CheckedService -> [ProcessReactionSnapshot]` in
`keiro-dsl/src/Keiro/Dsl/CoordinationImpact.hs` (line 216) both call `error` when
`checkedTypeGraph service` is `Left` or when `checkProcessReaction` fails. Their callers are
`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` lines 1158, 1200, and 1578, and tests at
`keiro-dsl/test/Main.hs` lines 8726, 8733, and 8739.

`keiro-dsl/src/Keiro/Dsl/Skeleton.hs` line 55 prefixes every `keiro-dsl new <kind>` skeleton
with `language keiro-dsl <currentAuthoringLanguageVersion>`. The test
`assertSkeletonUsesAuthoringLanguage` (`keiro-dsl/test/Main.hs` line 12638) asserts that the
skeleton's contract version equals `currentAuthoringLanguageVersion` and that its support level
is `Candidate`. `docs/user/typed-spec-toolchain.md` lines 29 to 32 say released-only services
should remain on Language 5 until the candidate is published.

The gate pieces this plan must keep green are `just process-reaction-proof` (runs
`keiro-dsl/test/process-reaction-mutation-test.sh`, which mutates the two fixtures with `sed`
and expects the conformance suites to fail, then `keiro-dsl/test/process-hydration-test.sh`),
`cabal test keiro-dsl:tests` (every keiro-dsl suite), `just dsl-api-boundaries`
(`scripts/check-keiro-dsl-api-boundaries.py`, which enforces constructor and private-module
export boundaries), `just conformance-corpus-policy`, and `just record-migration-policy`
(`python3 scripts/generate-record-migration-manifests.py --check`, which fails whenever a
public record field changes without regenerating `keiro-dsl/record-field-migration-0.15.md`
and `keiro-dsl/generated-haskell-edition-idiomatic-v2.md`).

Relevant ADRs, all local:

- `docs/adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md`
  requires deterministic-id seeds to be hashed as UTF-8 bytes through
  `Keiro.DeterministicId.identitySeedBytes`, names the code-point truncation as the collision
  bug it fixed, and freezes the derivation once shipped. The reaction template violates it in
  code it generates; this plan brings the candidate into line and amends the ADR to name the
  generated reaction derivation as a fifth frozen derivation once Language 6 publishes.
- `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md` states
  that registration is not release: a candidate's syntax, runtime profile, fixtures, and
  documentation may change until a package containing it is published, and published
  versions are never widened. That is what permits amending the two candidate corpora in
  place.
- `docs/adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md`
  states that persisted pre-hash bytes come only from `Keiro.Dsl.CanonicalEncoding` and that
  presentation pretty printing may evolve independently. The fingerprint change follows it.
- `docs/adr/0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md`
  records the runtime reaction contract that generated code targets: accepted witnesses,
  target-keyed dispatch identity, and the drain required when an identity family changes.
- `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` states that
  tooling depends on machine-readable `DiagnosticCode` values rather than prose, which is why
  the rollout metadata must agree with the finding text.

Sibling plans under the same MasterPlan: `docs/plans/281-restore-a-green-verify-gate-for-the-0-17-0-0-candidate.md`
re-establishes the corpus baseline this plan regenerates on top of (soft dependency: start
from a tree where `just conformance-corpus-policy` passes).
`docs/plans/284-gate-ordering-fifo-heads-to-language-6.md` adds a `LanguageFeature` to
`profileV5` in `LanguageVersion.hs`; this plan adds no feature and does not touch that profile.
`docs/plans/283-reconcile-the-0-17-0-0-changelogs-and-user-documentation-with-the-shipped-surfaces.md`
owns the structure of `keiro-dsl/CHANGELOG.md`; this plan appends bullets under its
`[Unreleased]` headings without reorganizing them.


## Plan of Work

### Milestone 1: reaction timer identity uses length-prefixed UTF-8 fields

Scope: the reaction template only. At the end, generated reaction code derives every timer id
and fired-event id from the UTF-8 bytes of length-prefixed fields, the two candidate corpora
are regenerated, the hand-written timers suite computes its expectations the same way, and a
unit test pins literal vectors including a non-ASCII pair that collided before.

In `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, inside `emitReactionProcessGen`, replace the two
lines that emit `namedUuid` (the `"namedUuid :: Text -> UUID"` and `"namedUuid value = ..."`
strings near line 5780) with a helper that takes the two fields separately. Emit, in the
generated module:

```haskell
reactionIdentity :: Text -> Text -> UUID
reactionIdentity prefix correlation =
  UUID.V5.generateNamed UUID.V5.namespaceURL (identitySeedBytes (T.concat (map field [prefix, correlation])))
  where
    field value = T.pack (show (BS.length (encodeUtf8 value))) <> ":" <> value
```

This is exactly the recipe of `deterministicReactionCommandId` and of
`Keiro.Inbox.Delegated.delegatedEventId`: each field becomes its decimal UTF-8 byte length, a
colon, and the field text, the fields are concatenated, and the whole is hashed as UTF-8
bytes. Because `identitySeedBytes` is UTF-8 encoding, hashing the concatenated text is
byte-identical to concatenating the encoded fields. Add the imports the helper needs to the
`hasTimers`-guarded import list at lines 5606 to 5610: `import Data.ByteString qualified as BS`,
`import Data.Text.Encoding (encodeUtf8)`, and `import Keiro.DeterministicId
(identitySeedBytes)`. Keep `import Data.UUID.V5 qualified as UUID.V5` and `import Data.Text
qualified as T` (the latter is already conditional on `processNeedsTextPack`; make sure the
condition also holds when `hasTimers`). Change `timerIdExpression` (line 5785) to render
`TimerId (reactionIdentity "<prefix>" <correlation>)` and the `firedId` line in
`renderTimerFire` (line 5795) to `EventId (reactionIdentity "<fired-event prefix>"
timer.correlationId)`. Search the same function for any other `namedUuid` use (the `cancel`
follow-up at corpus line 122 is rendered from the same `timerIdExpression`, so it follows
automatically; confirm with `grep -n namedUuid` on the regenerated corpus, which must return
nothing under `conformance-process-reactions` and `conformance-process-timers`).

Do not touch `emitProcessGen`. After the edit, `grep -n 'namedUuid' keiro-dsl/src/Keiro/Dsl/Scaffold.hs`
must show only the legacy template's lines (6067, 6092, 6093 at the reviewed commit).

Update `keiro-dsl/test/conformance-process-timers/Main.hs`: replace the body of
`expectedEscalationTimerId` (line 180) with the same length-prefixed derivation, importing
`Keiro.DeterministicId (identitySeedBytes)` and the byte-length helpers. Check whether
`keiro-dsl/test/conformance-process-reactions/Main.hs` computes any timer id; at the reviewed
commit it uses `probeSourceUuid` (line 169) only for synthetic source-event ids, which are
inputs rather than generated identities, so leave it alone.

Add a unit test in `keiro-dsl/test/Main.hs` next to the existing reaction diff tests (around
line 8655) named "derives reaction timer ids from length-prefixed UTF-8 fields". It must
scaffold `test/fixtures/process-timers.keiro` into a temporary directory with
`executePlannedScaffold` (the helper the neighbouring scaffold tests use), read the generated
`Process.hs`, and assert that it contains `reactionIdentity` and does not contain `namedUuid`.
It must also pin two literal vectors computed independently in the test with
`UUID.V5.generateNamed UUID.V5.namespaceURL (identitySeedBytes ...)`: the ASCII correlation
`inc_01h455vb4pex5vsknk084sn02q` under prefix `incident-escalation-timer:`, and the pair of
correlation ids `"\x0101"` and `"\SOH"` (U+0101 and U+0001, which are congruent modulo 256),
asserting that the old truncating derivation gives them one UUID and the new derivation gives
two. Write the expected UUID text literals into the test once computed so the derivation is
frozen by the test, not merely self-consistent.

Regenerate the two corpora and prove nothing else moved:

```bash
cabal build keiro-dsl:exe:keiro-dsl
just corpus-regen
git status --short -- keiro-dsl/test
```

The status must list only files under `keiro-dsl/test/conformance-process-timers/` and
`keiro-dsl/test/conformance-process-reactions/`. Then run the two suites, the mutation proof,
and the corpus policy. Acceptance: `cabal test keiro-dsl:keiro-dsl-conformance-process-timers
keiro-dsl:keiro-dsl-conformance-process-reactions` passes, `just process-reaction-proof` prints
`ok: timer identity prefix mutation reddened generated conformance` and ends with `PASS`, and
`just conformance-corpus-policy` prints `conformance corpus: ok` after the regenerated files
are committed.

### Milestone 2: rollout vectors agree with the finding text

Scope: `Diff.hs` vector mapping and `DiffReport.hs` tests. At the end, the JSON report for a
reaction advisory whose text says "drain before deploy" lists `drain-required`, and the three
new breaking reaction codes are classified on the persisted-identity surface.

In the vector mapping in `keiro-dsl/src/Keiro/Dsl/Diff.hs`, extend the guard at line 406 so
that `ProcessReactionFanOutChanged`, `ProcessReactionGuardChanged`,
`ProcessReactionArmsReordered`, and `ProcessReactionRemoved` map to
`replaceRollout (Set.singleton RolloutDrainRequired) (advisoryVector PrivateHistoryRead
Set.empty)`; keep them advisory (verify with the existing `deriveLabel`/`defaultGate` tests
that they do not become gated breaking). Add `ProcessTimerRemoved`,
`ProcessReactionVersionDecreased`, and `ProcessReactionFingerprintChangedWithoutVersionBump`
to the `identityCodes` list at line 447 so they take `persistedIdentityBreakingVector`; the
second `identityCodes` list at line 3544, used for change-context roots, must gain the same
three entries so `persistedIdentityContext` is chosen for them. Read
`ProcessReactionFingerprintChangedWithVersionBump` as well: it is advisory today and should
also carry `RolloutDrainRequired`, since `docs/user/deploy-ordering.md` line 143 already
promises "remains a drain-required advisory".

Add tests in `keiro-dsl/test/Main.hs` beside the JSON report tests (search for
`"rollout"` in the test file to find them) that diff `test/fixtures/process-timers.keiro`
against the in-memory variants the existing test at line 8655 already constructs
(`fanOutChanged`, `withoutReminder`, `versionTwo`), render the report with the same function
the CLI uses, and assert: the fan-out advisory's `rollout` array equals `["drain-required"]`
and its first remedy is the deployment-order remedy; `ProcessTimerRemoved` reports
`persistedIdentity` as `breaking` and `privateHistoryRead` as `not-applicable`. Use the
existing `rolloutName` and the report's surface field names as they appear in the test file
rather than guessing spellings.

Acceptance: `cabal test keiro-dsl-test --test-options='--match "/rollout/"'` (adjust the
pattern to the describe block you extend) passes, and the CLI transcript below shows the
constraint:

```bash
cabal run -v0 keiro-dsl -- diff keiro-dsl/test/fixtures/process-timers.keiro /tmp/process-timers-fanout.keiro --format json | jq '.changes[] | select(.code=="ProcessReactionFanOutChanged") | .rollout'
```

expected output:

```text
["drain-required"]
```

(Create `/tmp/process-timers-fanout.keiro` by copying the fixture and replacing `+ 5m` with
`+ 10m`, as the unit test does. If the CLI's JSON key names differ from `.changes[]`, use the
names the report test asserts.)

### Milestone 3: the fingerprint is a frozen canonical encoding of reaction semantics

Scope: `ProcessReaction.hs`, `CanonicalEncoding.hs`, tests, and the two candidate corpora
(their ledgers store the fingerprint). At the end, the fingerprint excludes operator text, is
computed from a frozen encoder, and is pinned by a golden.

Add `canonicalReactionSurface :: ReactionBody -> Text` to
`keiro-dsl/src/Keiro/Dsl/CanonicalEncoding.hs` and export it. Encode, in this order and with
explicit tuple boundaries in the style of `canonicalTransition`: the reaction version; each
input's name and its field list; each `on` node's input name and its arms, where an arm
encodes its guard through `canonicalExpr` (or the literal words `unconditional` and
`otherwise`), its advance command and accepted-only follow-ups, and its follow-ups
(dispatches with target, command, and policy choices; schedules with timer name, mode, and
fire-at expression; cancels with timer name); the dispatch-id strategy; the rejected and
poison policies; and each timer's name, id prefix, payload shape, fire target, command,
bindings, fired-event prefix, dispositions, and decode rule. Leave out `timers max-attempts`
and `dead-letter` entirely. Define the encoding by walking the `ReactionBody` record types in
`keiro-dsl/src/Keiro/Dsl/Grammar.hs` (search for `data ReactionBody`, `data ReactionNode`,
`data ReactionArm`, `data ArmBody`, `data FollowUp`, and the timer record) rather than by
re-using pretty-printer output, and read `canonicalTransition` first so the new encoder uses
the same delimiter conventions.

Change `processReactionFingerprintFrom` in `ProcessReaction.hs` (line 369) to hash the new
encoder's output. Add a golden test that pins the canonical text and the resulting SHA-256 for
`test/fixtures/process-timers.keiro` and `test/fixtures/process-reactions.keiro` under
`keiro-dsl/test/fixtures/` (follow the naming of the existing canonical goldens, which you can
find with `ls keiro-dsl/test/fixtures | grep -i canonical`). Extend the test at line 8655 so
that `codes isBreaking baseline ceilingChanged` is asserted to be empty and the advisory list
is exactly `[ProcessTimerCeilingChanged]`, and add a `deadLetterChanged` variant (replace the
dead-letter string) with the same assertions. Keep the existing "ignores formatting-only
process and timer surface rewrites" test at line 8741 passing; add a case that reformats the
reaction fixture (via `shouldParseStableRenderedSpec`) and asserts the fingerprint is unchanged.

Because the ledgers under both candidate corpora record the fingerprint, run `just
corpus-regen` again and confirm only those two directories changed. Acceptance: the golden
test passes, the ceiling and dead-letter diffs report only `ProcessTimerCeilingChanged`, and
`grep -rn fingerprint keiro-dsl/test/conformance-process-timers/keiro-dsl-ledger.context.process-timers.txt`
shows the new value.

### Milestone 4: harness facts, partial helpers, and skeleton language

Scope: three small, independent corrections.

Harness. Change `processHarnessFactValues` in `keiro-dsl/src/Keiro/Dsl/Harness.hs` to take
the checked ownership. The simplest shape is `processHarnessFactValues :: Text -> ProcessNode
-> [(Text, Text)]` where the first argument is the `verification` text, computed at the call
site (line 477 is inside a function that has `CheckedService` reachable through
`harnessForCheckedWithGoldens`; use `checkedTypeGraph` and `checkProcessReaction` there, and
fall back to `custom-unverified` when either fails, matching what
`processReactionRowsForService` records for legacy bodies). Add a test that scaffolds a
reaction fixture with a hole-owned accepted follow-up (the `custom-unverified` case; the
fixture `test/fixtures/process-state-authority.keiro` or a small inline variant that declares
an `on-accepted` follow-up whose proof is a hole) and asserts the generated harness fact reads
`custom-unverified`.

Partial helpers. Change `processReactionRowsForService` to return `Either (NonEmpty Text)
[ProcessReactionRecordRow]` and `processReactionSnapshots` to return `Either (NonEmpty Text)
[ProcessReactionSnapshot]`, rendering the type-graph or check failures with the same `show`
text the `error` calls use today. Thread the `Left` through the three call sites in
`ScaffoldRun.hs` (lines 1158, 1200, 1578) into the existing refusal path that reports a
validation failure (search that file for `Refusal` to find how other pre-scaffold failures are
surfaced), and update the tests at `keiro-dsl/test/Main.hs` lines 8726 to 8739 to match on
`Right`. `just dsl-api-boundaries` must still pass; if the script lists either function as a
protected export, update its expectation rather than bypassing it.

Skeletons. In `keiro-dsl/src/Keiro/Dsl/Skeleton.hs` line 55, use `currentStableLanguageVersion`
instead of `currentAuthoringLanguageVersion`. Check every skeleton for candidate-only syntax
(`grep -n -E 'reactions version|idempotence delegated|fifo-heads'
keiro-dsl/src/Keiro/Dsl/Skeleton.hs`); at the reviewed commit the `process` skeleton is a
legacy body and none uses candidate syntax, so every skeleton must still check on Language 5.
Update `assertSkeletonUsesAuthoringLanguage` at `keiro-dsl/test/Main.hs` line 12638 to assert
`currentStableLanguageVersion` and support level `Stable`, and rename it to reflect that. If
`currentAuthoringLanguageVersion` then has no remaining users outside its own module, leave it
exported (the API-boundary policy and consumers may reference it) but note the fact in the
Decision Log.

Acceptance: `cabal test keiro-dsl-test` passes; `cabal run -v0 keiro-dsl -- new process | head -1`
prints `language keiro-dsl 5`.

### Milestone 5: documentation, changelog, ADR amendment, full gate

Under `[Unreleased]` in `keiro-dsl/CHANGELOG.md`, add bullets: under New Features or Other
Changes as the owning structure dictates, that candidate reaction timer ids now derive from
length-prefixed UTF-8 fields (with a one-line statement that no published language changes);
that reaction advisories carry `drain-required` rollout metadata and the three breaking codes
classify on the persisted-identity surface; that the reaction fingerprint excludes operator
timer policy and is computed from a frozen canonical encoding; that harness ownership follows
the checker; and that `keiro-dsl new` targets the stable language. In
`docs/user/typed-spec-toolchain.md`, at the timer syntax reference near line 1045, add one
sentence: the id is UUIDv5 over the UTF-8 bytes of the length-prefixed prefix and correlation
id, so non-ASCII correlation ids never collide. In `docs/user/deploy-ordering.md` near lines
125 to 200, state that the reaction advisories are reported as `drain-required` in the JSON
report and that timer policy edits produce only `ProcessTimerCeilingChanged`. Each user
document edit must bump its `generated.at` timestamp and add a `docs/user/log.md` entry in the
form the file already uses. Amend
`docs/adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md` to
list the generated reaction timer derivation as frozen replay identity once Language 6 is
published, advancing its `timestamp` and adding a `docs/adr/log.md` entry with `okf log add`.

Then run the full gate from a clean tree:

```bash
just verify
nix flake check
```

Both must exit 0. `just verify` includes `process-reaction-proof`, `conformance-corpus-policy`,
`record-migration-policy`, `dsl-api-boundaries`, `adr-validate`, and
`user-documentation-validate`.


## Concrete Steps

All commands run from the repository root. Start from a clean tree on which
`just conformance-corpus-policy` already passes (see
`docs/plans/281-restore-a-green-verify-gate-for-the-0-17-0-0-candidate.md`).

Milestone 1:

```bash
git status --short            # must be empty
cabal build keiro-dsl:exe:keiro-dsl
grep -n 'namedUuid' keiro-dsl/src/Keiro/Dsl/Scaffold.hs
```

Edit `emitReactionProcessGen` as described, then:

```bash
cabal build keiro-dsl:exe:keiro-dsl
just corpus-regen
git status --short -- keiro-dsl/test
grep -rn 'namedUuid' keiro-dsl/test/conformance-process-timers keiro-dsl/test/conformance-process-reactions
cabal test keiro-dsl:keiro-dsl-conformance-process-timers keiro-dsl:keiro-dsl-conformance-process-reactions
just process-reaction-proof
```

Expected: the status lists only the two corpus directories, the `grep` prints nothing, both
suites pass, and the proof ends with `PASS: reaction guards, payload bindings, dispatch
commands, and timer identities are pinned`. Commit with the message shape:

```text
fix(dsl): derive candidate reaction timer ids from length-prefixed UTF-8 fields

MasterPlan: docs/masterplans/43-address-the-rev-17-keiro-0-17-0-0-release-readiness-findings.md
ExecPlan: docs/plans/285-harden-the-language-6-reaction-candidate-before-it-is-published.md
Intention: intention_01m2nqd9hre9gbhw37aagtf066
```

Milestone 2:

```bash
cabal test keiro-dsl-test --test-options='--match "/classifies reaction fan-out/"'
cabal run -v0 keiro-dsl -- diff keiro-dsl/test/fixtures/process-timers.keiro /tmp/process-timers-fanout.keiro --format json
```

Milestone 3:

```bash
cabal test keiro-dsl-test --test-options='--match "/fingerprint/"'
just corpus-regen
git status --short -- keiro-dsl/test
```

Milestone 4:

```bash
cabal test keiro-dsl-test --test-options='--match "/skeleton/"'
cabal run -v0 keiro-dsl -- new process | head -1
just dsl-api-boundaries
just record-migration-policy
```

If `record-migration-policy` reports a stale manifest because a public record changed (the
`Either` return types do not change records, but any new record field would), run
`python3 scripts/generate-record-migration-manifests.py` and commit the regenerated manifests.

Milestone 5:

```bash
just adr-validate
just user-documentation-validate
just verify
nix flake check
```


## Validation and Acceptance

The change is effective when all of the following hold on the final commit. Two correlation
ids that collide under the old derivation produce distinct timer ids: the unit test named in
Milestone 1 pins `"\x0101"` and `"\SOH"` to two different literal UUIDs and pins the ASCII
vector to its literal. The generated corpus contains no `namedUuid` under the two candidate
directories and the legacy corpora (`conformance-process`, `conformance-process-full`,
`conformance-process-runtime`, `conformance-process-state-authority`, `conformance-skeletons`)
are byte-identical to their state before this plan, which `git diff --stat` against the
starting commit proves. `just process-reaction-proof` still reddens on the timer-prefix
mutation. The JSON diff report for a fan-out change shows `["drain-required"]` in `rollout`.
Diffing a fixture whose only change is `max-attempts 5` to `max-attempts 7`, or whose only
change is the dead-letter string, yields exactly one advisory, `ProcessTimerCeilingChanged`, and
no breaking finding. Reformatting the reaction fixture leaves the fingerprint unchanged and the
golden pins its bytes. A reaction with a hole-owned accepted follow-up scaffolds a harness fact
`reactionOwnership=custom-unverified`. `cabal run -v0 keiro-dsl -- new process` begins with
`language keiro-dsl 5`. `just verify` and `nix flake check` exit 0.


## Idempotence and Recovery

Every step is repeatable. `just corpus-regen` is idempotent and refuses to run over
uncommitted corpus paths; if a regeneration leaves an unexpected file modified, inspect it
with `git diff` and restore with `git checkout -- keiro-dsl/test` before retrying. The
mutation script restores both fixtures' corpora on exit through its `trap`; if it is
interrupted, rerun `just corpus-regen` to restore the committed scaffold. Commit after each
milestone so a failing later milestone can be reverted alone. No database or migration is
involved. If Milestone 3's encoder cannot be made total for some `ReactionBody` shape, keep
the pretty-printer-based fingerprint, exclude only the timer policy line from it as an interim
step, record the gap in Surprises & Discoveries, and leave the milestone unchecked.


## Interfaces and Dependencies

Runtime: `Keiro.DeterministicId.identitySeedBytes :: Text -> [Word8]` (package `keiro`,
exposed module), `Data.UUID.V5.generateNamed` (package `uuid`), `Data.Text.Encoding.encodeUtf8`
and `Data.ByteString.length` for field lengths. Generated reaction modules gain the imports
`Keiro.DeterministicId (identitySeedBytes)`, `Data.ByteString qualified as BS`, and
`Data.Text.Encoding (encodeUtf8)`; the generated conformance packages already depend on
`keiro`, `bytestring`, `text`, and `uuid` (check the `keiro-dsl-cabal-fragment.context.*.txt`
under each candidate corpus and the corpus stanzas in `keiro-dsl/keiro-dsl.cabal`; add
`bytestring` if a stanza lacks it).

At the end of Milestone 1 the generated `Process.hs` for any reaction process with timers
exports the same names as today and defines `reactionIdentity :: Text -> Text -> UUID`. At the
end of Milestone 2, `Keiro.Dsl.Diff` classifies the seven named codes as described and
`Keiro.Dsl.DiffReport.remediationFor` yields `RemedyDeploymentOrder RolloutDrainRequired` first
for the four advisories. At the end of Milestone 3, `Keiro.Dsl.CanonicalEncoding` exports
`canonicalReactionSurface :: ReactionBody -> Text` and
`Keiro.Dsl.ProcessReaction.processReactionFingerprintFrom :: ReactionBody -> Text` hashes it.
At the end of Milestone 4, `Keiro.Dsl.ScaffoldRecord.processReactionRowsForService ::
CheckedService -> Either (NonEmpty Text) [ProcessReactionRecordRow]`,
`Keiro.Dsl.CoordinationImpact.processReactionSnapshots :: CheckedService -> Either (NonEmpty
Text) [ProcessReactionSnapshot]`, `Keiro.Dsl.Harness.processHarnessFactValues :: Text ->
ProcessNode -> [(Text, Text)]`, and `Keiro.Dsl.Skeleton` prefixes skeletons with
`currentStableLanguageVersion`.
