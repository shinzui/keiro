---
id: 141
slug: correct-the-evolution-documentation-and-deploy-ordering-guidance
title: "Correct the evolution documentation and deploy-ordering guidance"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
intention: intention_01ky7q57fbevsszaj32g77f6vt
master_plan: "docs/masterplans/24-close-the-evolution-and-replayability-gate-gaps-surfaced-by-the-2026-07-evolution-review.md"
---

# Correct the evolution documentation and deploy-ordering guidance

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Four user-facing documents describe a keiro that no longer exists, and the guidance a
deployed service most needs — in what order to roll out an evolution so nothing decodes
wrongly or dead-letters in the window — exists nowhere in `docs/user/` at all. The July
2026 evolution review verified each drift: `docs/user/codecs-and-event-evolution.md`
shows pre-`EventType` codec and upcaster signatures and omits four error constructors;
`docs/guides/evolve-events-safely.md` shows a three-argument `decodeRaw` that does not
type-check; `docs/user/snapshots.md` shows a `Custom` snapshot policy missing its
`Terminality` argument and (worse) claims state-shape changes update the snapshot hash —
the exact opposite of the truth that plan 138 is closing; and
`docs/user/replay-safety.md` covers single-version safety only, never saying that
*editing* guards or updates re-interprets the already-stored log. Meanwhile the only
deploy-ordering sentence in the entire codebase is a module haddock in
`keiro-pgmq/src/Keiro/PGMQ/Codec.hs`.

After this plan, the four drifted documents say true things; a new
`docs/user/deploy-ordering.md` states the rolling-deploy rules that exist only as code
today (aggregate codec bumps are not rolling-deploy-safe at all — stop-the-world or
blue/green cutover, with roll-forward-only as the rollback corollary;
workers-before-producers for versioned job codecs; drain-before-deploy for decide changes
over process-manager/router redelivery windows; the direct-write metadata hazard;
unversioned timer payloads; manual consumer-side integration versioning; the workflow
step-result crash ladder; and the pre-deploy replay audit as the standard gate for any
transducer change, cited from docs/plans/142 as planned until it lands); and
every touched document cross-links the companion guide
`docs/guides/evolution-and-replayability.md`. Sections that describe the gates plans
138/139/140 are building say "planned — see docs/plans/…" until those plans land, per
master plan 24, and this plan updates them to present tense as each lands.

A reader can verify the outcome directly: every type signature and constructor list shown
in the four documents compiles against the current source (each is verified against a
named file and line in this plan), and `docs/user/README.md` lists the new deploy-ordering
page.


## Progress

- [x] M1 (2026-07-23T18:16:15Z): `codecs-and-event-evolution.md` and `evolve-events-safely.md` corrected against current `Keiro.Codec`; companion-guide cross-links added; `just website-verify` passed (163 HTML pages).
- [x] M2 (2026-07-23T18:17:45Z): `snapshots.md` corrected (`Custom`/`Terminality`; three-component discriminator and manual-bump residual documented); `replay-safety.md` now covers evolution over time, retirement, replay-only edges, and the planned real-log audit; `just website-verify` passed (163 HTML pages).
- [x] M3 (2026-07-23T18:20:16Z): `docs/user/deploy-ordering.md` written with nine current rollout rule groups; `docs/user/README.md` indexed it; feature-doc pointers landed; `just website-verify` passed (163 HTML pages).
- [ ] Close-out: planned-gate references flipped to present tense for any of plans 138/139/140/142 that landed before this plan closes; master plan 24 EP-4 box ticked; ADR distillation pass.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (2026-07-23): the companion guide that this plan originally excluded from
  edits still describes the pre-EP-1/2/3 world: it says the startup boundary never calls
  `mkCodec`, generated harnesses use current-shape stand-ins, generated job queues are
  unversioned, snapshot compatibility has only two components, and event deprecation
  passes every gate. Cross-linking the corrected reference docs to that guide would leave
  mutually contradictory user guidance. The close-out therefore includes a surgical
  shipped-gate tense/truth sweep of the guide; its change-class structure remains intact.


## Decision Log

- Decision: Deploy-ordering guidance becomes a new single page,
  `docs/user/deploy-ordering.md`, indexed from `docs/user/README.md`, rather than
  sections scattered into the existing per-feature docs.
  Rationale: The rules cut across features (codecs, queues, routers, timers, workflows,
  integration) and an operator planning a rollout needs them in one place; the
  per-feature docs get one-line pointers instead of duplicated rule text, so there is a
  single source to keep true. The companion guide's "Deploy-ordering rules" section
  (docs/guides/evolution-and-replayability.md) stays the narrative treatment; the user
  doc is the reference statement of the same rules and links to it.
  Date: 2026-07-23

- Decision: Sections that describe gates delivered by plans 138/139/140/142 are written now
  in "planned" form with an explicit plan-path citation ("planned — see
  docs/plans/138-gate-snapshot-staleness-on-fold-changes.md"), and this plan's close-out
  flips each to present tense only after the cited plan lands.
  Rationale: Master plan 24's Integration Points make EP-4 the owner of all evolution-doc
  edits and require docs to track shipped behaviour, not intentions; the plan-path form
  keeps the docs honest at every intermediate commit.
  Date: 2026-07-23

- Decision: This plan quotes gate contracts from the sibling plans' Decision Logs
  (138: discriminator components and the manual `stateCodecVersion` contract; 139:
  boundary mkCodec check, deprecation hazard wording, golden convention; 140: dispatch
  rung semantics and the generated QueueCodec drain-first rule) rather than restating
  them from code.
  Rationale: That is the convention master plan 24 sets (same as master plan 18): EP-1-3
  record externally visible contracts in Decision Logs precisely so EP-4 can quote a
  stable sentence instead of re-deriving one.
  Date: 2026-07-23

- Decision (reconciled with the companion guide's authored findings): the deploy-ordering
  page frames aggregate codec bumps as "not rolling-deploy-safe at all", not merely
  "roll-forward-only". `Keiro.Codec` cannot express decode-vN-while-writing-vN-1 (decode
  target = `schemaVersion`; `VersionAhead` for any stored stamp above it,
  `keiro-core/src/Keiro/Codec.hs:266-269`), so old replicas fail hydration of any stream
  containing a vN event during a rolling window. The page prescribes stop-the-world or
  blue/green cutover, keeps roll-forward-only as the rollback corollary, and records the
  two-phase decode-then-write capability as explicit future work.
  Rationale: The guide's authoring surfaced that "roll-forward-only" understates the
  hazard — it reads as "just deploy in order", while the real constraint forbids the
  mixed-version window entirely. The user-facing reference must carry the sharper
  framing.
  Date: 2026-07-23

- Decision: The workflow recovery API is referenced strictly as a pointer to
  docs/plans/115-record-patch-sets-at-rotation-and-add-workflow-failure-recovery-and-lease-renewal.md
  (master plan 16's EP-4), never described as existing.
  Rationale: At authoring time the terminal `WorkflowFailed` state has no recovery API;
  promising one that has not landed is exactly the class of doc drift this plan removes.
  Date: 2026-07-23

- Decision: Supersede the original "companion guide is cross-linked only" file exclusion
  for a narrow close-out truth sweep now that plans 138, 139, and 140 have landed.
  Rationale: The guide explicitly promises to state which gates catch each mistake today,
  but still presents those three completed plans as future work. Leaving those claims
  untouched would violate this plan's user-visible outcome and make the new deploy-ordering
  reference point readers at false operational advice. This revision updates only shipped
  gate status and links; it does not restructure or replace the guide.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/keiro`) contains the keiro runtime and
its documentation. User documentation lives in `docs/user/` (indexed by
`docs/user/README.md`); narrative guides live in `docs/guides/`. The companion guide
`docs/guides/evolution-and-replayability.md` was authored together with master plan 24 —
it is the narrative "what to do per change class" document, it already exists, and this
plan must NOT rewrite it; this plan only cross-links it and keeps the `docs/user/`
reference pages true. The sibling implementation plans are
`docs/plans/138-gate-snapshot-staleness-on-fold-changes.md`,
`docs/plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md`,
`docs/plans/140-fix-dsl-upcaster-lowering-and-adopt-versioned-job-codecs.md`, and
`docs/plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md`;
this plan is soft-dependent on all four (it documents their shipped shapes and cites them
as planned until then).

Architectural ground truth that the corrected docs must convey. keiki (at
`/Users/shinzui/Keikaku/bokuno/keiki`) has no separate decide/evolve — one edge set is
both forward stepping and replay: replay re-inverts each stored event back to a command
and re-checks the edge guard (`keiki/src/Keiki/Core.hs:1223-1228`), so editing a guard,
output, or update expression edits the interpretation of the existing log; keiro surfaces
replay failures as `HydrationNoInvertingEdge` and friends
(`keiro/src/Keiro/Command.hs:457-462`). Upcasters run at decode-time forever — hydration
(`keiro/src/Keiro/Command.hs:410`), the workflow journal
(`keiro/src/Keiro/Workflow.hs:690`), and `keiroJobCodec`
(`keiro-pgmq/src/Keiro/PGMQ/Codec.hs:85-106`) — and there is no stored-data migration
mechanism anywhere.

The verified drift, item by item (each is a claim this plan corrects, with the source of
truth to correct it against):

1. `docs/user/codecs-and-event-evolution.md:10-19` shows
   `eventTypes :: NonEmpty Text`, `eventType :: e -> Text`,
   `decode :: Value -> Either Text e`, and
   `type Upcaster = (Int, Value -> Either Text Value)`. Current truth
   (`keiro-core/src/Keiro/Codec.hs:65,84-92`): `eventTypes :: NonEmpty EventType`,
   `eventType :: e -> EventType`, `decode :: EventType -> Value -> Either Text e`,
   `type Upcaster = (Int, EventType -> Value -> Either Text Value)`. The doc's error
   list (lines 92-99) omits `VersionAhead`, `IncompleteUpcasterChain`,
   `MalformedSchemaVersionStamp`, and `NonObjectCallerMetadata`
   (`Codec.hs:95-122`), and shows `UnknownEventType EventType [Text]` where the second
   field is `[EventType]`. `mkCodec` (`Codec.hs:142-165`) is never mentioned in any user
   doc. Line 85's rule "Keep upcasters consecutive from every stored version you still
   support" implies unsupporting is possible; it is not — there is no unsupport
   mechanism, a missing rung is `GapInUpcasterChain`/`IncompleteUpcasterChain` forever
   (`Codec.hs:277-280`).
2. `docs/guides/evolve-events-safely.md:39` shows `decodeRaw orderCodec 1 (object …)` —
   three arguments; the real signature is
   `decodeRaw :: Codec e -> EventType -> Int -> Value -> Either CodecError e`
   (`Codec.hs:247`). Line 27 shows the upcaster as `Value -> Either Text Value` without
   noting the tag-taking chain position (`const`-wrapped in the real codec).
3. `docs/user/snapshots.md:46` shows `Custom (state -> StreamVersion -> Bool)`; the real
   constructor is `Custom !(Terminality -> state -> StreamVersion -> Bool)`
   (`keiro-core/src/Keiro/EventStream.hs:81-86`). Lines 80-83 claim register-file *or
   state shape* changes update the `shapeHash` automatically — false: with today's
   `defaultStateCodec` the hash covers the register-file layout only
   (`keiro/src/Keiro/Snapshot/Codec.hs:38-48`, hash of `Proxy @rs` at line 41;
   `keiki/src/Keiki/Shape.hs:195-239` — slot names and canonical type *names* in order,
   nothing else). Plan 138 lands the minimal factual fix to that paragraph *and* changes
   the underlying truth (a state-shape hash and fold fingerprint); this plan owns the
   full section rewrite and must coordinate — if plan 138 landed first, build on its
   corrected paragraph (it leaves a `<!-- plan 141: full rewrite -->` marker) and
   describe the new three-component discriminator by quoting plan 138's Decision Log;
   if not landed, describe today's two-component truth and cite plan 138 as planned.
4. `docs/user/replay-safety.md` is accurate about single-version construction-time
   safety but silent on evolution: nothing tells the reader that decide/guard/update
   *edits* are replay-relevant (the ground truth above), and its "What Keiro Does Not
   Prove" list (lines 151-169) does not include fold-change snapshot staleness or
   deprecation-vs-replayability.

The missing deploy-ordering guidance, item by item (each verified against code; these
become `docs/user/deploy-ordering.md`):

- Aggregate codec version bumps are not rolling-deploy-safe *at all* — not merely
  roll-forward-only. `Keiro.Codec` cannot express "decode vN while still writing vN-1":
  the decode target IS the codec's single `schemaVersion`, and any stored stamp above it
  fails `VersionAhead` (`keiro-core/src/Keiro/Codec.hs:266-269`). So during a rolling
  window, the moment one new replica appends a vN event, every old replica fails
  hydration of any stream containing it — the correct procedures are stop-the-world or
  blue/green cutover, with roll-forward-only as the *rollback* corollary (after the first
  vN write, redeploying old code cannot read the stream; recovery is restore-from-backup).
  A two-phase decode-then-write capability (read vN while writing vN-1) does not exist
  and must be recorded as future work, not implied. No doc says any of this anywhere; the
  only ordering doc in the codebase is keiroJobCodec's workers-before-producers haddock
  (`keiro-pgmq/src/Keiro/PGMQ/Codec.hs:15-20`).
- Missing metadata decodes as version 1 (`Codec.hs:291-308`, default at 298/301): any
  process writing events to kiroku directly, without `encodeForAppend`'s stamp, plants
  payloads that will be misread as v1 after the first bump — a mixed-writer hazard.
- Timer payloads cross deploys unversioned: the timer row carries opaque JSON
  (`keiro/src/Keiro/Timer/Types.hs:33`), so a fire decoder must tolerate every payload
  shape ever scheduled or the timer ping-pongs until `maxAttempts` dead-letters it
  (`keiro/src/Keiro/Timer.hs:68-73`; at-least-once contract and claim semantics,
  `Timer.hs:101-123`).
- Consumer-side integration versioning is fully manual: `decodeJsonIntegrationEvent` is
  plain `FromJSON` with no envelope or upcasting
  (`keiro-core/src/Keiro/Integration/Event.hs:291-304`); the producer-first vs
  consumer-first rule follows the contract-bump semantics the DSL differ encodes —
  field additions require a schemaVersion bump and coordinated rollout
  (`keiro-dsl/src/Keiro/Dsl/Diff.hs:698-704`: bumped addition is an advisory
  "coordinate the cross-service rollout"; unbumped addition is breaking because older
  in-flight messages lack the field).
- Decide changes over process-manager/router redelivery windows need a drain: dispatch
  ids are deterministic per (router, correlation, source event, target, occurrence)
  (`keiro/src/Keiro/Router.hs:166-189`), and a redelivered source event whose new-code
  fan-out overlaps the old-code fan-out has its duplicates *confirmed as benign* and
  skipped (`Router.hs:284-285`, `confirmBenignDuplicate`) — so a half-old/half-new
  fan-out across a deploy is silently merged, never flagged. The rule: drain or pause
  the subscription over the deploy when a decide change alters fan-out for in-window
  events.
- A workflow step-result type change crashes replay of the journal: after the resume
  worker's default five attempts (`maxAttempts = 5`,
  `keiro/src/Keiro/Workflow/Resume.hs:168,191`) the instance is marked terminally
  `WorkflowFailed` (`Resume.hs:363-378`). The recovery API is the deliverable of
  docs/plans/115 (master plan 16) — reference by path only.

Ownership: this plan owns ALL evolution-doc edits in `docs/user/` and `docs/guides/`
except the guide itself (not edited) and plan 138's single-paragraph snapshots.md fix
(coordinated above). No source code changes belong to this plan. Relevant ADRs:
`docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` is tangential (its span
contract is unaffected by anything documented here); the snapshot-discriminator ADR and
evolution-gate-inventory ADR may exist by the time this plan runs (created by plans
138/139) — if they do, cite them from the corrected docs instead of duplicating their
content.

Term definitions used in the new docs (define them there too, in plain language):
"roll-forward-only" — once the new version has written a single event, old binaries can
no longer read the stream, so rollback means restore-from-backup, not redeploy-old-code;
"drain" — stop feeding a worker (pause the subscription/queue) and let in-flight work
finish before switching versions; "redelivery window" — the span during which an
already-processed source event can be delivered again (crash before checkpoint,
visibility timeout, consumer rebalance).


## Plan of Work

### Milestone 1 — make the codec documents true

Scope: `docs/user/codecs-and-event-evolution.md` and
`docs/guides/evolve-events-safely.md` match the current `Keiro.Codec` surface, name every
error constructor, document `mkCodec`, and stop implying upcasters can be dropped.

In `codecs-and-event-evolution.md`: replace the code block at lines 10-19 with the
current record and upcaster type (copy the shapes from
`keiro-core/src/Keiro/Codec.hs:65,84-92` and re-typecheck by eye against the source, not
memory); extend the Decoding section to say `decode` receives the stored event-type tag
and that upcasters receive it too (the tag is authoritative for multi-event codecs — and,
once plan 140 lands, note that DSL-generated rungs dispatch on it; until then cite plan
140 as planned); rewrite the error list from `Codec.hs:95-122` with all ten
constructors and one-line meanings, including which appear only on encode
(`NonObjectCallerMetadata`, `InvalidSchemaVersion`, `UnknownEventType`) and which only on
decode; add a short `mkCodec` section — what it checks (`Codec.hs:142-165`), why the raw
constructor is an escape hatch, and the boundary status: validated at
`mkEventStream`-time (cite plan 139 as planned until landed, then present tense);
replace the "still support" versioning rule with the truth: upcasters are forever — every
version ever written must keep a contiguous chain to current, and there is no unsupport
mechanism; and correct the closing claim that codec errors surface as
`HydrationDecodeFailed` *or* `EncodeFailed` by adding where each appears. Add a
cross-link line to `docs/guides/evolution-and-replayability.md` and to
`docs/user/deploy-ordering.md` (created in M3; add the link in M3 if sequencing this
milestone first).

In `evolve-events-safely.md`: fix line 39 to the four-argument call —

```haskell
decodeRaw orderCodec (EventType "OrderPlaced") 1
  (object ["orderId" .= ("order-100" :: Text), "qty" .= (3 :: Int)])
```

— and re-verify the shown expectation against the actual jitsurei test it cites
(`jitsurei/test/Main.hs`, "Jitsurei codec evolution" group; if the test text drifted too,
fix the guide to match the test, never the reverse); annotate the upcaster signature at
line 27 with the chain position truth (the codec stores
`(1, const upcastOrderPlacedV1)`; the tag parameter exists for multi-event codecs);
extend the closing checklist with "check in a golden old-version payload" once plan
139/140 land the convention (cite as planned until then). Cross-link the companion guide.

Acceptance: every signature and constructor list in both documents grep-matches the
cited source lines; a reviewer following each doc's code block against
`keiro-core/src/Keiro/Codec.hs` finds zero mismatches; `git diff` confined to the two
files.

### Milestone 2 — make the snapshot and replay documents true

Scope: `snapshots.md` shows the real `SnapshotPolicy` and tells the truth about the
discriminator; `replay-safety.md` gains the evolution boundary it silently lacks.

In `snapshots.md`: fix the `SnapshotPolicy` block at lines 41-47 to include
`Terminality` (copy from `keiro-core/src/Keiro/EventStream.hs:81-86`) and add one line
explaining the argument (whether the fold has reached a terminal state, so `Custom`
policies can snapshot-on-close). Rewrite the "process managers" paragraph at lines 78-83
and the `StateCodec` section together, in whichever of two worlds holds at execution
time: (a) plan 138 landed — describe the three-component discriminator
(`stateCodecVersion`, register-file `shapeHash`, `stateShapeHash` with the optional
`;fold=` fingerprint), what each invalidates automatically, the one-time full-replay on
upgrade, and the surviving manual contract (Holes-only/hand-written fold-logic changes
still need a `stateCodecVersion` bump) — quoting plan 138's Decision Log wording and
replacing its `<!-- plan 141: full rewrite -->` marker; or (b) not landed — state
today's truth (hash covers register slot names/canonical type names/order only; state
type and fold logic invisible; bump `stateCodecVersion` for ALL of those) and cite plan
138 by path as the planned gate. Also add the staleness warning the review surfaced:
a fold change with an unbumped codec serves stale seeds silently and the post-append
verification re-persists stale-derived state at the new head (cite plan 138's fix
status accordingly).

In `replay-safety.md`: add a section "Replay Safety Over Time" after "What Keiro Does
Not Prove", stating the ground truth in user terms: validation proves the *current*
machine is replay-safe; it does not prove the current machine replays *yesterday's*
log the way yesterday's machine wrote it. One edge set serves forward execution and
replay, and replay re-derives each stored event's command and re-checks the guard — so
editing guards, outputs, or updates changes what the existing log means; removing an
emitting transition makes stored events unreplayable (`HydrationNoInvertingEdge`) even
though they still decode. Extend the "What Keiro Does Not Prove" list with fold-change
snapshot staleness and deprecation-vs-replayability, each with its gate status (cite
plans 138/139 as planned/landed). Close with a pointer to the companion guide for the
per-change-class procedure.

Acceptance: the `SnapshotPolicy` block matches `EventStream.hs:81-86` exactly; the
snapshots.md discriminator paragraphs contain no claim contradicted by
`Snapshot/Codec.hs`/`Snapshot/Schema.hs` at whatever revision is checked out; the new
replay-safety section names the two failure modes with their error constructors.

### Milestone 3 — write the deploy-ordering reference and wire the links

Scope: `docs/user/deploy-ordering.md` exists, states the seven rule groups from Context
with their code citations, and every touched page links coherently.

Write `docs/user/deploy-ordering.md` with this structure (prose, one section per rule
group, each ending with the observable failure if the rule is violated): (1) The general
principle — events are forever, decoders are per-binary; every rollout question is
"which binaries can read what the other binaries write during the window". (2) Aggregate
event codec bumps: NOT rolling-deploy-safe — a codec cannot decode vN while still
writing vN-1 (its decode target is its own `schemaVersion`; a stored stamp above it is
`VersionAhead`), so one new replica's first vN append breaks hydration on every old
replica for any stream containing it. Prescribe stop-the-world or blue/green cutover for
aggregate codec bumps (never mixed writer versions against one stream category), and
state the rollback corollary separately: roll-forward-only — after the first vN write,
old binaries cannot read the stream, so rollback means restore-from-backup, not
redeploy-old-code. Record explicitly that a two-phase decode-then-write capability is
future work that does not exist today. (3) Versioned job queues (`keiroJobCodec`): workers before
producers; `JobPayloadFromFuture` retries cover the window — size
`maxRetries × defaultRetryDelay` accordingly; never switch a non-empty queue's codec
shape — drain first (quote plan 140's generated-module wording once landed). (4) Decide
changes over redelivery windows: drain or pause PM/router subscriptions when fan-out
changes, because deterministic dispatch ids silently confirm duplicates across the
deploy — half-old/half-new fan-outs merge without any signal. (5) Direct-store writers:
events appended without keiro's encoder are stamped nothing and decode as v1 after the
first bump — either always append through the codec or never bump. (6) Timers: payloads
are opaque and unversioned; fire decoders must accept every historically scheduled
shape or the timer dead-letters after `maxAttempts`; treat timer payload evolution as
producer-first-never (schedule new shapes only after all firers understand them).
(7) Integration events: consumer decode is plain `FromJSON` — additive producer changes
require the contract schemaVersion bump and a consumer-first rollout for
required-field additions / producer-first for optional ones; cross-service conformance
checking is manual today (deferred initiative, per master plan 24's Decision Log).
(8) Workflows: a step-result type change crashes resume; after five attempts the
instance is `WorkflowFailed` terminally; recovery API is the deliverable of
docs/plans/115 — do not rely on it until that plan lands. (9) The replay audit: for any
transducer change (guards, outputs, updates, transition removal, fold edits), run the
candidate binary's replay audit against a production-copy or staging database before
switching traffic — non-zero exit (a stream that fails replay, or a snapshot seed that
diverges from full replay) means do not deploy; quote the audit contract from
docs/plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md's
Decision Log once landed, cite it as planned until then. Front-matter paragraph links
the companion guide's "Deploy-ordering rules" section as the narrative version.

Update `docs/user/README.md`: add the page to the index (alongside Operations), one
line: "Deploy Ordering (deploy-ordering.md): which binaries must roll first for codec,
queue, decide, timer, integration, and workflow changes." Add the one-line pointers from
`codecs-and-event-evolution.md`, `snapshots.md`, `replay-safety.md`, `outbox.md`/
`inbox.md` (integration ordering), `process-managers-and-timers.md` (drain rule), and
`durable-workflows.md` (step-result rule) to the new page — pointers only, no duplicated
rule text.

Close-out: sweep the four documents for any "planned — see docs/plans/…" reference whose
plan has since landed and flip it to present tense; tick master plan 24's EP-4 progress
box and registry row; run the ADR distillation pass (if the evolution-gate-inventory ADR
exists, verify the docs cite it; if this plan discovered doc-worthy contract ambiguities,
record them in the sibling ADR rather than only in prose).


## Concrete Steps

This plan is documentation-only; the "build" is verification. All commands run from
`/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
# Verify every signature the docs will show, against source (spot-check loop):
grep -n "type Upcaster" keiro-core/src/Keiro/Codec.hs
grep -n "decodeRaw ::" keiro-core/src/Keiro/Codec.hs
grep -n -A 6 "data SnapshotPolicy" keiro-core/src/Keiro/EventStream.hs
grep -n -A 12 "data CodecError" keiro-core/src/Keiro/Codec.hs

# Confirm gate landing status before choosing tense (world (a) vs (b) in M2):
git log --oneline -- keiro/src/Keiro/Snapshot/Codec.hs | head -5
ls docs/plans/138-gate-snapshot-staleness-on-fold-changes.md   # read its Progress section

# Link integrity (the website build checks internal links):
just website-verify
```

Expected: the grep outputs match the code blocks pasted into the docs verbatim;
`just website-verify` (which runs the site build plus `site/check-links.mjs`) exits zero
— it is the only automated gate for docs and MUST be run after every milestone. If the
site toolchain is unavailable in the environment, fall back to
`node site/check-links.mjs site-dist` after `pnpm run build`, and record the substitution
in Progress.


## Validation and Acceptance

Acceptance is that the documents are *checkably* true. (1) Every Haskell block in the
four corrected documents corresponds to a named file:line in this plan's Context, and a
reviewer diffing block-vs-source finds zero drift. (2)
`docs/user/codecs-and-event-evolution.md` lists all ten `CodecError` constructors and
documents `mkCodec`. (3) `docs/guides/evolve-events-safely.md`'s `decodeRaw` example has
four arguments and matches the jitsurei test it cites. (4) `docs/user/snapshots.md`
contains no sentence claiming state-shape or fold changes update the hash unless plan
138's gate has landed and the sentence describes it accurately. (5)
`docs/user/deploy-ordering.md` exists, is indexed, and each of its nine sections names
the observable failure mode with its error constructor or mechanism
(`VersionAhead`, `JobPayloadFromFuture`, benign-duplicate confirmation, v1 default
stamp, timer dead-letter, `FromJSON` decode failure, `WorkflowFailed`). (6) Every
"planned" citation points at an existing plan file path; none describes unlanded work in
present tense. (7) `just website-verify` passes.


## Idempotence and Recovery

Documentation edits are trivially re-runnable and revertable per file with git. The one
ordering hazard is tense: if this plan completes before some sibling lands, the
"planned" citations are correct and MUST NOT be flipped speculatively; the close-out
sweep is the designated flip point and can be re-run any time later as a follow-up
commit (note it in this plan's Progress when that happens). If plan 138's minimal
snapshots.md fix and this plan's rewrite race, resolve in favor of whichever text is
true for the code actually on the branch — the marker comment identifies plan 138's
paragraph.


## Interfaces and Dependencies

No code interfaces. Files owned/edited: `docs/user/codecs-and-event-evolution.md`,
`docs/guides/evolve-events-safely.md`, `docs/user/snapshots.md`,
`docs/user/replay-safety.md`, `docs/user/deploy-ordering.md` (new),
`docs/user/README.md`, plus one-line pointers in `docs/user/outbox.md`,
`docs/user/inbox.md`, `docs/user/process-managers-and-timers.md`,
`docs/user/durable-workflows.md`. Files explicitly NOT edited:
`docs/guides/evolution-and-replayability.md` (authored with master plan 24; cross-linked
only) and the master plan itself (except its Progress/registry rows at close-out, which
its own protocol requires). Soft dependencies: plans 138, 139, 140, 142 (tense of gate
descriptions; quoted Decision Log contracts). Source-of-truth files verified against:
`keiro-core/src/Keiro/Codec.hs`, `keiro-core/src/Keiro/EventStream.hs`,
`keiro-core/src/Keiro/Integration/Event.hs`, `keiro/src/Keiro/Snapshot/Codec.hs`,
`keiro/src/Keiro/Timer.hs`, `keiro/src/Keiro/Timer/Types.hs`,
`keiro/src/Keiro/Router.hs`, `keiro/src/Keiro/Workflow/Resume.hs`,
`keiro-pgmq/src/Keiro/PGMQ/Codec.hs`, `keiro-dsl/src/Keiro/Dsl/Diff.hs`.
