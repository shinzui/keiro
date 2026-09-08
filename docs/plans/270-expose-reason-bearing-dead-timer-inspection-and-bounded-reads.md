---
id: 270
slug: expose-reason-bearing-dead-timer-inspection-and-bounded-reads
title: "Expose reason-bearing dead timer inspection and bounded reads"
kind: exec-plan
created_at: 2026-09-08T02:12:07Z
intention: "intention_01m1zchqgtenp9a759tcv0vtkw"
---

# Expose reason-bearing dead timer inspection and bounded reads

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Distill durable decisions into docs/adr/ before completion.


## Purpose / Big Picture

Applications will be able to inspect why a timer was parked, retrieve its original work, and browse a bounded set of dead timers through `Keiro.Timer`. A dead timer is durable work excluded from the ordinary worker's scheduled-work queue. Applications can distinguish deliberately deferred work from exhausted retries without querying Keiro's tables. A PostgreSQL fixture will demonstrate reason-preserving reads and application-owned permission filtering, including a page containing no authorized entries followed by one containing authorized work.

This implements the read contract in [IR-35](docs/improvement-requests/expose-reason-bearing-dead-timer-reads.md). It does not implement the separate guarded mutation in [IR-36](docs/improvement-requests/support-atomic-guarded-dead-timer-resume.md). Reading an eligible row does not reserve it or authorize execution.


## Progress

- [x] (2026-09-08T02:26Z) Confirmed schema compatibility, public facade, Hasql codecs through Mori, and ADR boundaries. Inspection tests failed to compile against the old API as expected (`lookupTimerInspection` not in scope).
- [x] (2026-09-08T02:29:14Z) Implemented inspection and bounded listing; focused timer tests passed all 19 examples, including the six new inspection/filter/pagination/authorization cases.
- [x] (2026-09-08T02:29:14Z) Consumer authorization fixture passed; user documentation and ADR-28 strict validation passed. `nix fmt`, `nix flake check`, and all seven `cabal check` commands passed.
- [ ] Complete full-suite/workspace/operator checks and record final documentation/package evidence.
- [ ] Coordinate release with IR-36 and record tagged Hackage/docs evidence.
- [ ] Record downstream released-bound adoption and passing Kioku fixture.

## Surprises & Discoveries

The first focused test run rebuilt dependencies and confirmed the intended compile failure for the absent public inspection operation. The new SQL mode encoder requires an explicit `Data.Int (Int32)` import because `Keiro.Prelude` exports `Int64` only.

IR-36 remains proposed with no guarded dead-timer mutation in the working tree. The coordinated release therefore cannot yet satisfy its joint scope; local read implementation must not mark IR-35 delivered or present a source overlay as released adoption.

## Decision Log

Decision (2026-09-08): Implement both additive read operations in one source change and validate inspection, listing, and consumer fixtures together; the red compile test independently proves the old API lacks inspection. No dependency bounds, versions, or migrations change. Hackage/tag verification still finds 0.15.0.0 at `de574cdcb0add3fefbb0fdd96d820258d15f8997`. Keep the coordinated release and downstream released-bound fixture pending until IR-36 is ready.
Decision (2026-09-08): Validate IR-35 as actionable. At repository commit `7ffd251983be1439f113c3529e6087d48e5ed6ac`, `deadLetterTimerStmt` persists `last_error`, but `TimerRow`, `lookupTimerStmt`, and `timerRowDecoder` omit it; `findStuckTimersStmt` selects only firing rows. Existing schema already supports the requested information. The request's underlying defect is confirmed independently of its historical source revision.

Decision (2026-09-08): Add `TimerInspection` containing the unchanged `TimerRow` plus `Maybe Text` reason. This preserves constructor, record, generic representation, lookup, and worker compatibility. SQL NULL, empty text, and populated text remain distinct. No new migration or dependency bound is planned.

Decision (2026-09-08): Use exact optional manager filtering and explicit any/absent/exact/literal-prefix reason modes, with ascending timer-ID pagination and a hard page cap of 100. Timer IDs are immutable UUID keys; this avoids mutable timestamp cursors and defines a simple total database order. Listing is not chronological or a snapshot spanning multiple requests.

Decision (2026-09-08): Plan creation does not close IR-35. Implementation and consumer proof precede completion; publication is coordinated with IR-36 through the existing release workflow. The request remains proposed until the evidence it requires exists.


## Outcomes & Retrospective


## Context and Orientation

`keiro/src/Keiro/Timer.hs` is the public facade: it explicitly re-exports storage types and operations from `keiro/src/Keiro/Timer/Schema.hs`, plus worker operations. `keiro/src/Keiro/Timer/Types.hs` defines `TimerId` and `TimerRequest`. `TimerRow` is currently defined in Schema and carries timer ID, process-manager name, correlation ID, original due time, JSON payload, lifecycle status, attempt count, and optional fired event ID. A process manager coordinates work across events; its name here is an ownership label, not an authorization credential. Correlation ID identifies the consumer's related work.

Schema uses parameterized Hasql statements executed through `runTransaction` and the store effect. `timerRowDecoder` decodes eight selected columns. Reuse it inside the new inspection decoder, then decode nullable `last_error`. Keep the old projections and decoder unchanged. `keiro-migrations/migrations/0004-keiro-timer-recovery.sql` already added the nullable reason column. The existing timer primary key supports ordered ID traversal; the due index is partial for scheduled rows and does not accelerate dead-state filtering. A bounded result limits returned rows, not necessarily database work; do not claim an indexed reason search or constant query cost.

`keiro/test/Main.hs` runs Hspec through `withMigratedSuite` and has a `describe "Keiro.Timer"` group using `withFreshStore`. `keiro-test-support/src/Keiro/Test/Postgres.hs` provisions migrated ephemeral PostgreSQL fixtures. Existing tests schedule, claim, cancel, fire, and dead-letter timers through the public API. Add focused tests in that group to reuse its fixture and request helpers. Internal test-only SQL is appropriate for a legacy dead row with NULL reason and for comparing all persisted columns before and after reads; consumer-facing examples must use only public operations.

[ADR-28](docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md) requires consumers and operator adapters to use supported operations supplied by the schema owner. These reads supply that missing primitive. [ADR-36](docs/adr/0036-external-readers-use-versioned-guarded-sql-contracts.md) was also consulted: its guarded SQL functions concern external projection reads and rebuild compatibility. This plan adds a Haskell timer API, not a new SQL grant surface or projection contract. No existing ADR defines dead-reason matching or timer-page semantics. During implementation, update ADR-28 with the inspection and caller-authorization boundary if it merits durable clarification. The ADR bundle uses `docs/adr/profile.dhall`; preserve stable doc IDs and enforce its profile and log when editing records.

The downstream requirement is `mori://shinzui/kioku/plans/41-configure-all-kioku-ai-features-through-baikai-and-honor-host-execution-policy`. Registry discovery located its checkout even though `mori path` could not resolve the plan artifact during validation. Its source confirms a stored category beginning `kioku:deferred:interactive-unavailable feature=` and a worker that calls `deadLetterTimer`. Retain the full stored text; Keiro must not parse Kioku's memory-space identity or define its reason taxonomy.

Hackage's `https://hackage.haskell.org/package/keiro/preferred.json` reported 0.15.0.0 as the newest normal version during validation on 2026-09-08 UTC. Upstream `keiro-0.15.0.0` resolves to commit `de574cdcb0add3fefbb0fdd96d820258d15f8997`. This establishes a release baseline, not a promise about the future adoption version. Recheck both before choosing release or consumer bounds.


## Plan of Work

### Milestone 1: Preserve reasons in a compatible public inspection read


In `keiro/src/Keiro/Timer/Schema.hs`, add the inspection type, private decoder, private statement, and `lookupTimerInspection`. Select the same eight columns in the same order as `lookupTimerStmt`, followed by `last_error`. Decode it with `D.column (D.nullable D.text)`. Re-export the type and operation from `keiro/src/Keiro/Timer.hs`. The lookup works for every lifecycle state and returns `Nothing` for an absent ID. It executes only SELECT, without row-claim locks or mutations.

Add public-import tests in `keiro/test/Main.hs` proving absent ID, NULL, empty text, populated text, Unicode text, and preservation of every original metadata field, including fired event ID on a fired row. Explicitly compare old `lookupTimer` results with the inspection's nested row. Run the focused timer command below; the new tests must fail to compile before the addition and pass afterward, with existing timer cases still passing.

### Milestone 2: Add bounded dead-state filtering and deterministic pages


Define the types and functions in Interfaces and Dependencies in Schema, with facade re-exports. Validate page size before querying: only 1 through 100 succeeds. Invalid sizes produce `Left` with the original requested size, never an unbounded query or silent clamping. One SELECT combines `status = 'dead'`, optional manager equality, reason mode, and exclusive UUID cursor comparison. Use typed nullable parameters and explicit SQL casts where NULL tests would otherwise leave parameter types ambiguous.

Exact and prefix comparisons are case-sensitive literal comparisons; use deterministic `C` collation for text comparisons so database locale cannot make exact matching case-insensitive. For prefix matching compare the leading `char_length(prefix)` characters with the supplied prefix instead of interpreting SQL LIKE patterns. Percent, underscore, and backslash are ordinary characters. Empty prefix selects every non-NULL reason, including empty text; absent reasons require `ReasonAbsent`. Manager and reason predicates combine with AND.

Order by `timer_id ASC` and fetch at most requested size plus one. Return at most the requested number and set continuation to the final returned timer ID only if the extra row exists. An empty or exhausted page has no continuation. Encode the UUID itself; do not compare display strings. A cursor means continue strictly after this ID under the same filters, even if the cursor row has been deleted. Restart with no cursor after changing filters.

Write mixed-state, mixed-manager fixtures and verify exact, absent, prefix, wildcard-literal, empty, and Unicode behavior. Test boundaries 1 and 100, invalid negative/zero/101/maximum Int sizes, repeated reads, empty pages, and multi-page traversal. Between page requests, remove or change the eligibility of a row and insert controlled IDs on either side of the cursor. Later requests observe then-current eligibility: IDs at or below the cursor are not revisited, and IDs above it may newly appear. There is no complete-snapshot guarantee under concurrent changes. Run focused timer tests and the full Keiro test suite.

### Milestone 3: Prove the consumer contract and prepare release evidence


Add a consumer-style test in `keiro/test/Main.hs` whose listing and inspection imports come solely from `Keiro.Timer`. Use synthetic payloads with an application-owned space field, fresh permission sets, and the observed deferred-reason prefix. Decode payloads and filter permissions before rendering. Skip malformed payloads without leaking their contents. Follow the storage continuation even when an entire page becomes empty after authorization filtering. Revoke permission between requests and demonstrate that the next render omits that space. This fixture proves the integration pattern; actual downstream adoption remains separate evidence.

Document signatures, reason modes, page limits, ordering, concurrency, permission ownership, full reason preservation for IR-36, and compatibility in `docs/user/process-managers-and-timers.md`. Update `docs/capabilities/process-managers-routers-timers.md` only when implementation evidence exists and add an unreleased root `CHANGELOG.md` entry. Follow those bundles' existing timestamp/log conventions and their Justfile validators. Record validation and the plan link in IR-35 without marking it delivered prematurely.

Coordinate the tagged Hackage release with IR-36 using `agents/skills/release/SKILL.md`. That workflow releases the shared package cohort, regenerates version-stamped corpus artifacts, runs its release gates, and obtains review of concrete version/changelog changes before publication. Do not choose a release number during this planning task. Recheck registry/tag baselines, run `nix fmt`, `just corpus-regen`, `just verify`, `nix flake check`, package checks/source distributions/Haddock, and the publication and verification sequence specified there. Keep publication evidence pending until tags, Hackage artifacts, and docs are live.

For actual adoption, locate the current downstream checkout through `mori registry show shinzui/kioku --full`, read its local instructions and the canonical plan above, and add the public-API deferred-listing fixture there under its existing AI timer tests. Run its documented test command and record the exact command, released bound, and commit in this plan. Require authorized-space omission and original work/reason rendering, with no direct Keiro table reads. If downstream work or release is pending, report that remaining milestone honestly rather than closing IR-35 or claiming the local simulation as downstream proof.


## Concrete Steps

All Keiro commands run from the repository root. Use the Nix development shell if tools are not already available; PostgreSQL test fixtures are ephemeral and must not point at a production database.

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
nix develop -c cabal test keiro-test --test-options='--match Keiro.Timer' --test-show-details=direct
nix develop -c cabal test keiro-test --test-show-details=direct
nix develop -c cabal build all
nix develop -c cabal test keiro-ops-test --test-show-details=direct
```

The focused Hspec output must list the new inspection/filter/pagination/authorization cases and end with zero failures. The full suite and operator suite must report PASS; workspace compilation proves existing worker and operator consumers still build. Do not record these as run during plan creation.

Before release selection, recheck:

```bash
curl -fsSL https://hackage.haskell.org/package/keiro/preferred.json
git ls-remote --tags origin 'keiro-*'
mori registry search hasql
mori registry docs hasql/hasql
```

Read dependency source through Mori before changing dependency API use or bounds. If ADR-28 is edited, type-check its descriptor and follow the existing `okf log add --help` interface to append its revision, then validate:

```bash
dhall --file docs/adr/profile.dhall >/dev/null
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just user-documentation-validate
just capabilities-validate
git diff --check
```

During implementation, add timestamped progress checklist entries at each stopping point. Commits use Conventional Commits and both trailers:

```text
ExecPlan: docs/plans/270-expose-reason-bearing-dead-timer-inspection-and-bounded-reads.md
Intention: intention_01m1zchqgtenp9a759tcv0vtkw
```


## Validation and Acceptance

A scheduled row reads with `lastError = Nothing`; a dead-letter operation with empty text reads `Just ""`; a populated reason reads byte-for-byte equivalent text without trimming, annotation, or category extraction. A legacy dead row with NULL remains distinguishable from all of these. The nested row equals the legacy lookup and retains payload, owner, correlation, due time, status, attempts, and fired event ID.

Given two deferred rows for manager A, one for manager B, an ordinary dead letter, and rows in all other states, manager A plus the literal deferred prefix returns exactly its two eligible dead rows. Page size one traverses them in UUID order without duplicates on unchanged data, and the final page has no continuation. ReasonAbsent selects only NULL dead reasons; exact empty selects only empty ones. Invalid page sizes return the specified error. Parameter text containing quotes, percent, underscore, and backslash cannot change SQL meaning.

Compare every stored timer column, including `created_at`, `updated_at`, `attempts`, `status`, and `last_error`, before and after lookup, listing, exhausted-page calls, and failed size validation. Reads must change none of them. Run an ordinary due-worker poll afterward to prove inspected dead rows remain unclaimable. A public read result is observation, never a claim or authorization token.

The local consumer fixture must render authorized original work only, use the full stored reason, and continue beyond an authorization-empty page. Actual downstream acceptance records the released package version and a passing fixture in the canonical Kioku plan. Release and adoption evidence are completion requirements, not implied by local passing tests.


## Idempotence and Recovery

Read operations and isolated tests can be repeated safely. No applied migration changes are required. If performance evidence later justifies a dead-row index, revise this plan first and add a new migration with schema snapshot and migration validation; never edit migration 0004. Do not add indexes speculatively while promising arbitrary prefix queries are indexed.

Pagination under concurrent changes is intentionally observational. Consumers restart to discover entries that became eligible behind their cursor. A later recovery action must revalidate its own guards through IR-36. Failed development checks are fixed and rerun; failed release uploads stop dependent publication and are reconciled using the release workflow. Do not reset user changes or drop a shared database to repair tests.


## Interfaces and Dependencies

Define these additive exports in `keiro/src/Keiro/Timer/Schema.hs` and re-export them through `keiro/src/Keiro/Timer.hs`. Use the repository's strict records and Generic/Eq/Show conventions. `Eff es` denotes a computation using the existing store effect; database failures follow the same outer store error behavior as `lookupTimer`.

```haskell
data TimerInspection = TimerInspection
  { timer :: !TimerRow,
    lastError :: !(Maybe Text)
  }

data TimerReasonFilter
  = AnyTimerReason
  | ReasonAbsent
  | ReasonExact !Text
  | ReasonPrefix !Text

data DeadTimerFilter = DeadTimerFilter
  { processManagerName :: !(Maybe Text),
    reason :: !TimerReasonFilter
  }

anyDeadTimer :: DeadTimerFilter
-- DeadTimerFilter Nothing AnyTimerReason

data DeadTimerPageRequest = DeadTimerPageRequest
  { pageSize :: !Int,
    afterTimerId :: !(Maybe TimerId)
  }

data DeadTimerReadError = InvalidDeadTimerPageSize !Int

data DeadTimerPage = DeadTimerPage
  { timers :: ![TimerInspection],
    nextAfterTimerId :: !(Maybe TimerId)
  }

lookupTimerInspection ::
  (Store :> es) => TimerId -> Eff es (Maybe TimerInspection)

findDeadTimers ::
  (Store :> es) =>
  DeadTimerFilter -> DeadTimerPageRequest ->
  Eff es (Either DeadTimerReadError DeadTimerPage)
```

Keep `TimerRow`, `lookupTimer`, `findStuckTimers`, and all worker signatures unchanged. Use the existing Hasql parameter/decoder composition and store transactions. Source and encoder guidance were located via `mori://hasql/hasql`; public decoder exports include `rowMaybe`, `rowList`, `nullable`, and `text`. No new library, dependency bound, database role, HTTP endpoint, memory-space schema, or AI execution capability is introduced.

Revision (2026-09-08): Began implementation, recorded the red compilation test and explicit release/adoption dependencies.
