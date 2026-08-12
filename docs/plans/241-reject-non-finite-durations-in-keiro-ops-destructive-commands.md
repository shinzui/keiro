---
id: 241
slug: reject-non-finite-durations-in-keiro-ops-destructive-commands
title: "Reject non-finite durations in keiro-ops destructive commands"
kind: exec-plan
created_at: 2026-08-11T23:37:31Z
intention: "intention_01kzsjzp13e28vvrz7jfdve3dt"
master_plan: "docs/masterplans/37-fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review.md"
---

# Reject non-finite durations in keiro-ops destructive commands

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-ops` is this repository's operational command-line tool for running Keiro
deployments. Several of its destructive commands take a retention or age flag — for
example `keiro-ops outbox gc-sent --older-than 30d --force` deletes sent outbox rows
older than thirty days. Today the duration parser accepts the strings `NaN` and
`Infinity` (spellings Haskell's `Read Double` recognizes), and either one silently
collapses the retention cutoff to "right now" by the time it reaches PostgreSQL.
The verified consequence: `keiro-ops outbox gc-sent --older-than NaN --force` deletes
EVERY sent outbox row regardless of age (permanent loss of publish history),
`outbox requeue-stuck --older-than NaN --force` reclaims rows that are actively being
published (causing duplicate publications), and the same reader feeds `inbox gc`
(which would erase the inbox dedup ledger), `wf gc run-once --retention` (which would
hard-delete every terminal workflow), and `timer stuck list --min-age`. The 2026-08-11
pre-release review confirmed this defect, and 0.12.0.0 — the first stable release —
must not ship it.

After this plan, every numeric flag in keiro-ops rejects garbage at parse time, before
any preview, any `--force` mutation, or any database connection. The observable win: an
operator who runs `keiro-ops outbox gc-sent --older-than NaN` (with or without
`--force`, against any database URL) gets exit code 2 and the message
`invalid duration "NaN": expected a finite, non-negative number of seconds, optionally
with an s, m, h, or d suffix` on stderr, and nothing else happens. Legitimate inputs
(`30d`, `5m`, `1.5`, `2592000`, `1e6`) behave exactly as before.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Implementation started; read the complete ExecPlan and marked EP-5 in progress in
      the parent MasterPlan before changing CLI parsing (2026-08-12T19:44:48Z).
- [x] Milestone 1: `parseDuration` in `keiro-ops/src/Keiro/Ops/Parse.hs` rejects
      non-finite, negative, and wire-unrepresentable values with the exact messages
      documented in this plan (2026-08-12T19:46:50Z).
- [x] Milestone 1: the `parseDuration` unit matrix in `keiro-ops/test/Main.hs` covers
      every rejected spelling and every preserved accepted form; the full keiro-ops
      suite passes with 35 examples and zero failures (2026-08-12T19:46:50Z).
- [x] Milestone 2: the three unguarded `option auto` call sites
      (`wf list --limit`, `wf gc run-once --batch`, `replay-audit --resume-from`)
      use guarded readers (2026-08-12T19:49:52Z).
- [x] Milestone 2: `readBoundedIntegral` is added to `Keiro.Ops.Parse`; every
      `reads`-based integer reader parses through it (no silent 2^64 wraparound);
      the exact-duplicate `positiveIntReader`/`nonNegativeIntReader` copies are
      consolidated into `Keiro.Ops.Parse` (2026-08-12T19:49:52Z).
- [x] Milestone 2: pure command-tree rejection specs (via `execParserPure`) pass for
      every duration flag and the newly guarded integer flags; the full suite passes
      with 37 examples and zero failures (2026-08-12T19:49:52Z).
- [ ] Milestone 3: executable-level test proves `outbox gc-sent --older-than NaN`
      fails with the documented message and exit code 2 before any database contact.
- [ ] Milestone 3: `cabal test keiro-ops-test` fully green; MasterPlan 37 progress row
      for EP-5 updated; ADR distillation pass done (ADR 0028 consequence added).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Three findings from plan research (GHC 9.12.4, verified in this working tree on
2026-08-11) refine the review's original description of the defect:

1. `-Infinity` is already rejected by the existing `value < 0` guard, because
   `-Infinity < 0` is `True`. The actual holes in `parseDuration` are `NaN`, `-NaN`
   (Haskell reads it and `negate NaN` is still `NaN`), and positive `Infinity` —
   plus every suffixed spelling (`NaNs`, `NaNm`, `NaNh`, `NaNd`, `Infinityd`, ...)
   because the suffix is stripped before the number is read. Lowercase spellings
   (`nan`, `infinity`, `Inf`) are not accepted by `Read Double` and already fail.

2. The corrupted cutoff is not merely "far in the future" — for both `NaN` and
   `Infinity` it collapses to exactly `now` on the PostgreSQL wire. `toRational` of
   either value is a positive rational with a factor of 2^920 or greater; scaled to
   microseconds it is divisible by 2^64, so when hasql's binary timestamptz encoder
   (`utcToMicros` in postgresql-binary-0.15.0.1, `library/PostgreSQL/Binary/Time.hs`
   lines 106–110, which converts an unbounded `Integer` day count through
   `fromIntegral` into `Int64`) wraps it modulo 2^64, the astronomical component
   vanishes entirely and the server receives `cutoff = now`. Evidence (a GHC
   evaluation modeling that encoder, `now` = 2026-08-11):

   ```text
   ("keepFor sign","1s")                              -- realToFrac NaN is POSITIVE
   ("cutoff year sign/digits","-854499414992130...")  -- astronomically far past
   ("wrapped Int64 micros since 2000","839721600000000")
   ("wrapped as years offset from 2000","26.60917180013689")  -- exactly 2026-08-11
   ```

   `published_at < now` matches every sent row, so a forced pass deletes all of them.

3. Rejecting only non-finite and negative values is not enough. A finite oversized
   duration wraps the same Int64 microsecond encoding into an arbitrary — possibly
   future — cutoff: `--older-than 1e13` (10^13 seconds) wraps to a cutoff about
   267,688 years in the future, which also deletes everything. Evidence from the same
   model: `("finite 1e13s wrapped µs, years-from-2000","(8447583795309551616,267687.777...)")`.
   This forced the representability bound recorded in the Decision Log.

Related, same class, lower severity: `Read Int` silently wraps out-of-range literals
modulo 2^64 — `read "18446744073709551716" :: Int` evaluates to `100` — so every
`reads`-based limit/batch reader accepts a huge literal as a silently different small
number. Milestone 2 closes this.

(Implementation-time surprises to be added as work proceeds.)

- Milestone 1 reproduction (2026-08-12): the tests-first duration matrix failed in
  exactly the two unsafe classes. `NaN` was admitted as an enormous positive
  `NominalDiffTime`, and `1e13` was admitted unchanged; the preserved ordinary and
  existing malformed-input rows were already green. This confirmed the guard was the
  only missing boundary before applying it to the scaled product.


## Decision Log

Record every decision made while working on the plan.

- Decision: Fix `parseDuration` by guarding the `Read Double` result after suffix
  scaling (reject `isNaN`, `isInfinite`, negative, and over-bound on the scaled
  product), rather than replacing `Read` with a dedicated numeric grammar.
  Rationale: the guard is the minimal diff, is total over every verified hole class
  (`NaN`/`Infinity` propagate through multiplication; the multiplier is positive so a
  negative input yields a negative product; finite overflow such as `1e308d` becomes
  `Infinity` and is caught), and preserves every currently valid spelling including
  scientific notation (`1e6`). A stricter grammar would change the accepted surface
  without adding safety. Guarding the scaled product (not the raw value) is essential:
  `1e308` passes a pre-scaling check but `1e308 * 86400` is `Infinity`.
  Date: 2026-08-11
- Decision: In addition to non-finite and negative values, reject finite durations
  greater than 9.0e12 seconds (about 285,000 years) with a distinct message. Do not
  add any operational-policy cap (such as "at most 10 years").
  Rationale: the initial recommendation was to reject non-finite and negative only,
  with no arbitrary cap. Plan research falsified its safety premise: the PostgreSQL
  binary timestamptz format is Int64 microseconds since 2000-01-01, its maximum is
  about 9.22e12 seconds, and a finite duration beyond that wraps to an arbitrary —
  verified future — cutoff with the same total-deletion outcome as `NaN` (see
  Surprises & Discoveries, item 3). MasterPlan 37's bar is that no known bug ships.
  The 9.0e12-second bound is a wire-representability constraint, not a policy cap:
  every duration up to roughly 285 millennia is still accepted, so no legitimate
  operator input is affected, while every value the encoding cannot represent is
  refused. A policy cap was rejected as arbitrary and hostile to deliberate
  keep-nearly-forever retention values.
  Date: 2026-08-11
- Decision: Close the sibling holes in the same plan: replace the three unguarded
  `option auto` call sites with guarded readers, and route every `reads`-based
  integer reader through a new `readBoundedIntegral` (parse as `Integer`, check the
  target type's bounds, then convert) exported from `Keiro.Ops.Parse`. Consolidate
  only the exact-duplicate readers (`positiveIntReader` ×7, `nonNegativeIntReader`
  ×3) into `Keiro.Ops.Parse`; keep domain-specific readers (distinct error messages)
  module-local but reimplemented over the helper.
  Rationale: these are the same class of hole — text that `Read` accepts but whose
  parsed value silently differs from what the operator wrote or violates the
  reader's stated contract. `wf gc run-once --batch` is a destructive command whose
  batch size was completely unvalidated. Full-message consolidation was rejected
  because several readers carry deliberately domain-specific errors ("expected a
  non-negative global position", "expected a positive message id") worth keeping.
  Date: 2026-08-11
- Decision: Freeze the two error-message texts in this plan and assert them exactly
  in unit tests (see Validation and Acceptance).
  Rationale: the message must name the offending input so an operator understands
  the refusal, and tests that assert the exact string prevent silent drift of the
  operator-facing contract.
  Date: 2026-08-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This repository is a Haskell multi-package cabal project rooted at
`/Users/shinzui/Keikaku/bokuno/keiro`. The package relevant here is `keiro-ops`
(directory `keiro-ops/`), an operational command-line interface over a Keiro
deployment's database. Its command modules live under `keiro-ops/src/Keiro/Ops/`
(one module per command domain: `Outbox.hs`, `Inbox.hs`, `Timer.hs`, `Workflow.hs`,
`Pgmq.hs`, `Rebuild.hs`, `ReplayAudit.hs`, `Shard.hs`, `Snapshot.hs`, `Stream.hs`,
`Projection.hs`), the entry point in `keiro-ops/src/Keiro/Ops.hs`, and the test suite
(hspec) in `keiro-ops/test/Main.hs`. Commands are declared with the
`optparse-applicative` library; a "reader" (`ReadM` value, built with `eitherReader ::
(String -> Either String a) -> ReadM a`) converts one command-line argument string
into a typed value or a parse error. Argument parsing happens in
`Keiro.Ops.mainWithHooks` (`keiro-ops/src/Keiro/Ops.hs` line 44) via
`customExecParser` BEFORE `runInvocation` resolves the connection string or touches
the database, and the command tree sets `failureCode 2`, so any reader failure exits
with code 2 having done nothing else. That ordering is what makes parse-time
rejection a complete fix.

The governing safety posture is
`docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`
(ADR 28): every destructive keiro-ops command is a thin adapter over a supported
exported operation of the owning library, and without `--force` it only previews the
rows it would affect and exits unsuccessfully. This plan serves that posture at the
layer in front of it: a preview computed from a garbage cutoff is a lie, and a forced
pass with a garbage cutoff is unbounded deletion, so validation must happen at parse
time before either phase. No other local ADR bears on this change, and no
cross-repository ADR applies (confirmed during MasterPlan 37 planning). The parent
initiative is
`docs/masterplans/37-fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review.md`
(this plan is its EP-5). The keiro-ops package version is currently 0.11.0.0; release
mechanics for 0.12.0.0 are explicitly out of scope for this plan.

### The defective parser

`keiro-ops/src/Keiro/Ops/Parse.hs` (37 lines) exports `durationReader :: ReadM
NominalDiffTime` and `parseDuration :: String -> Either String NominalDiffTime`.
`NominalDiffTime` (from the `time` package) is a length of wall-clock time stored as
a fixed-point picosecond count backed by an unbounded `Integer`. `parseDuration`
strips an optional one-letter unit suffix (`s`=1, `m`=60, `h`=3600, `d`=86400,
matched case-insensitively on the LAST character only), reads the remainder as a
`Double` with `Text.Read.readMaybe`, rejects `value < 0`, and returns
`realToFrac (value * multiplier)`.

Haskell's `Read Double` accepts, in addition to ordinary decimal and scientific
notation, exactly these non-finite spellings (verified in GHC 9.12.4; all lowercase
or abbreviated variants are rejected):

```text
readMaybe "NaN"       = Just NaN
readMaybe "-NaN"      = Just NaN          (negate NaN is NaN)
readMaybe "Infinity"  = Just Infinity
readMaybe "-Infinity" = Just (-Infinity)
readMaybe "nan" / "NAN" / "Nan" / "infinity" / "INFINITY" / "Inf" / "-inf" = Nothing
```

`NaN < 0` is `False` (every ordered comparison against NaN is `False`) and
`Infinity < 0` is `False`, so `NaN`, `-NaN`, and `Infinity` sail through the guard;
only `-Infinity` is caught. Because the suffix is stripped first, `NaNs`, `NaNm`,
`NaNh`, `NaNd`, and `Infinityd` reach the same hole, and a finite input can overflow
after scaling: `1e308d` passes the guard as `1e308` and becomes `Infinity` when
multiplied by 86400.

### How the garbage value reaches the database

Every duration flag flows into a cutoff of the form `addUTCTime (negate duration)
now` inside the owning library, which is then bound to a SQL comparison through
hasql's `timestamptz` encoder. The five consumers (found by auditing every use of
`durationReader` across `keiro-ops/src`):

- `outbox requeue-stuck --older-than` (default 5m) — `keiro-ops/src/Keiro/Ops/Outbox.hs`
  line 79; handler `runRequeue` (line 138) calls `requeueStuckOutbox` (forced) and
  `listStuckOutbox` (preview), both in `keiro/src/Keiro/Outbox/Schema.hs` (cutoff at
  lines 86 and 175; SQL predicate `status = 'publishing' AND updated_at < $1`).
- `outbox gc-sent --older-than` (default 30d) — `Outbox.hs` line 83; handler `runGc`
  (line 154) calls `garbageCollectSent` (forced, cutoff at
  `keiro/src/Keiro/Outbox/Schema.hs` line 122) and `listSentOutboxGcCandidates`
  (preview, line 97; SQL predicate `status = 'sent' AND published_at < $1`).
- `inbox gc --older-than` (default 30d) — `keiro-ops/src/Keiro/Ops/Inbox.hs` line 74;
  handler `runGc` (line 116) calls `garbageCollectCompleted` (forced, cutoff at
  `keiro/src/Keiro/Inbox/Schema.hs` line 152) and `listCompletedInboxGcCandidates`
  (preview). Deleting completed inbox rows destroys the consumer dedup ledger.
- `wf gc run-once --retention` (no default; required) — `keiro-ops/src/Keiro/Ops/Workflow.hs`
  line 215; handler `runGc` (line 475) builds `Gc.WorkflowGcPolicy options.retention
  options.batchSize` and calls `Gc.gcWorkflowsOnce` (forced) or
  `Gc.listWorkflowGcCandidates` (preview); the cutoff is computed at
  `keiro/src/Keiro/Workflow/GC.hs` line 103.
- `timer stuck list --min-age` (optional) — `keiro-ops/src/Keiro/Ops/Timer.hs`
  line 108; handler `runStuckList` (line 194) calls `findStuckTimers` with a
  `StuckTimerFilter` (`keiro/src/Keiro/Timer/Schema.hs` line 187). Read-only, but the
  listing that operators triage from would be nonsense.

The wire step is where the damage becomes concrete. The statements bind the cutoff
with `E.param (E.nonNullable E.timestamptz)` (hasql). hasql encodes `UTCTime` with
postgresql-binary's `utcToMicros :: UTCTime -> Int64`
(postgresql-binary-0.15.0.1, `library/PostgreSQL/Binary/Time.hs` lines 106–110),
which converts the unbounded day count via `fromIntegral` into `Int64` — arithmetic
that wraps modulo 2^64 with no bounds check. Since Int64 wrapping is a ring
homomorphism from the true integer microsecond value, the server receives
`true_microseconds mod 2^64`. For a `NaN` or `Infinity` retention the astronomical
component is divisible by 2^64 and vanishes: the cutoff arrives as exactly `now`, and
a forced `gc-sent` deletes every sent row while a forced `requeue-stuck` reclaims
rows mid-publish (duplicate publication). For a finite retention above about 9.22e12
seconds the wrap lands elsewhere — verified: 1e13 seconds becomes a cutoff about
267,688 years in the FUTURE, which likewise matches (and deletes) everything. The
evidence transcripts are in Surprises & Discoveries.

### The full numeric-reader inventory

Audit of every keiro-ops flag that parses a number (every `ReadM` built over `Read`,
plus every `option auto`), with verdicts:

Duration (Double — the critical holes, fixed in Milestone 1): the single reader
`durationReader`/`parseDuration` in `keiro-ops/src/Keiro/Ops/Parse.hs`, feeding the
five flags listed above.

Unguarded `option auto` (accepts negatives, zero, and wrapped values — fixed in
Milestone 2):

- `wf list --limit` — `Workflow.hs` line 175, `auto :: ReadM Int`, default 100.
- `wf gc run-once --batch` — `Workflow.hs` line 216, `auto :: ReadM Int`, default
  100. Destructive command; a negative batch reaches
  `fromIntegral limit :: Int32` at `keiro/src/Keiro/Workflow/GC.hs` line 107 and
  fails only at the database as a negative SQL LIMIT, after connection and preview.
- `replay-audit --resume-from` — `ReplayAudit.hs` line 53, `auto :: ReadM Int64`
  wrapped in `GlobalPosition`; accepts negative positions.

Guarded `reads`-based integer readers (already reject `NaN`/`Infinity` because
`Read Int` does, and already enforce sign — but all silently wrap out-of-range
literals modulo 2^64, e.g. `--limit 18446744073709551716` parses as 100; fixed in
Milestone 2):

- `positiveIntReader` (message "expected a positive integer"), duplicated in
  `Inbox.hs` 87, `Outbox.hs` 105, `Pgmq.hs` 69, `ReplayAudit.hs` 66, `Stream.hs` 111,
  `Timer.hs` 129, `Workflow.hs` 243 — flags: `--limit` (inbox/outbox/pgmq/stream
  lists, timer drain-once, wf resume-once, dead-letters), `--max-attempts`,
  `--budget`, `--parallelism`.
- `nonNegativeIntReader` (message "expected a non-negative integer") in
  `Snapshot.hs` 86, `Stream.hs` 117, `Timer.hs` 123 — flags:
  `--state-codec-version`, `timer stuck list --min-attempts`.
- `nonNegativeInt64Reader` in `Rebuild.hs` 138 (message "expected a non-negative
  global position", flag `rebuild start --from`) and `Snapshot.hs` 92 / `Stream.hs`
  123 (message "expected a non-negative stream version", flags `--before`,
  `stream show --from`, `VERSION` argument).
- `positiveInt32Reader` in `Rebuild.hs` 144 (message "expected a positive 32-bit
  integer", flag `--page-size`).
- `int64Reader` in `Pgmq.hs` 75 (message "expected a positive message id", flag
  `pgmq dlq archive --entry`).
- `generationReader` in `Workflow.hs` 237 (message "expected a non-negative
  generation", flag `--generation`).

Non-numeric readers (`uuidReader`, `statusReader`, `utcReader`, `payloadReader`,
`groupReader`, `runReader`, text options) were inspected and are not affected: none
goes through `Read` on a numeric type.

### Test suite orientation

`keiro-ops/test/Main.hs` is one hspec `main` with a suite-level PostgreSQL fixture:
`withMigratedSuiteWith` (from `keiro-test-support`,
`keiro-test-support/src/Keiro/Test/Postgres.hs` line 89) starts a cached ephemeral
PostgreSQL server itself, so `cabal test keiro-ops-test` is self-contained — no
external database is needed. Parsing is already tested two ways there: pure
command-tree checks with `Optparse.execParserPure` via the local helpers `parseOps`,
`isParseSuccess`, and `isParseFailure` (lines 92–101), and executable-level checks
that locate the real binary with `keiroOpsExecutable` (line 980, via `cabal list-bin
exe:keiro-ops`; the test suite declares `build-tool-depends: keiro-ops:keiro-ops` so
it is always built) and run it with `readProcessWithExitCode`. There is an existing
`describe "parseDuration"` block at line 200 to extend. The exact test command,
taken from the `haskell-test` recipe in the repository `Justfile` (line 66), is
`cabal test keiro-ops-test`, run from the repository root.


## Plan of Work

All edits are in the `keiro-ops` package plus its test suite; no library (`keiro/`)
code changes, no schema changes, no dependency changes, no version bump.

### Milestone 1 — harden `parseDuration` (the confirmed data-loss defect)

Scope: rewrite the guard in `keiro-ops/src/Keiro/Ops/Parse.hs` and extend the
existing `describe "parseDuration"` unit block. At the end of this milestone the
data-loss defect is closed for all five duration flags at once (they share the one
reader), and unit tests prove every rejected and accepted spelling. Acceptance:
`cabal test keiro-ops-test` passes; running only the new specs before making the
code change shows them failing (see Concrete Steps).

Replace the body of `parseDuration` so the guard applies to the scaled product and
distinguishes malformed/non-finite/negative input from a finite value the wire
encoding cannot represent. The intended final content of the function (module
header, exports `durationReader` and `parseDuration`, and `durationFactor` are
unchanged; the error strings below are the frozen operator-facing contract):

```haskell
parseDuration :: String -> Either String NominalDiffTime
parseDuration input = do
  let (numberText, multiplier) =
        case reverse input of
          suffix : rest
            | Just factor <- durationFactor (toLower suffix) ->
                (reverse rest, factor)
          _ -> (input, 1)
  value <- maybe (Left malformed) Right (Read.readMaybe numberText :: Maybe Double)
  let scaled = value * multiplier
  if isNaN scaled || isInfinite scaled || scaled < 0
    then Left malformed
    else
      if scaled > maxDurationSeconds
        then Left tooLarge
        else Right (realToFrac scaled)
  where
    malformed =
      "invalid duration "
        <> show input
        <> ": expected a finite, non-negative number of seconds, optionally with an s, m, h, or d suffix"
    tooLarge =
      "invalid duration "
        <> show input
        <> ": exceeds the maximum supported duration of 9.0e12 seconds (about 285000 years)"

-- | Upper bound on any operator-supplied duration, in seconds. PostgreSQL's
-- binary timestamptz format is Int64 microseconds since 2000-01-01 (maximum
-- about 9.22e12 seconds); a larger duration wraps modulo 2^64 into an
-- arbitrary cutoff. 9.0e12 seconds is comfortably inside that range and far
-- beyond any legitimate retention.
maxDurationSeconds :: Double
maxDurationSeconds = 9.0e12
```

Note `show input` renders the offending argument in double quotes, so the message for
input `NaN` is exactly:

```text
invalid duration "NaN": expected a finite, non-negative number of seconds, optionally with an s, m, h, or d suffix
```

Why this shape is total over the holes: `NaN` and `Infinity` survive multiplication,
so checking `scaled` catches bare and suffixed spellings alike; the multiplier is
always positive, so a negative input yields a negative `scaled`; a finite value that
overflows during scaling (`1e308d`) becomes `Infinity` and is caught; a finite value
at most 9.0e12 converts losslessly into `NominalDiffTime` (picoseconds backed by
`Integer`) and produces a cutoff whose microsecond magnitude fits Int64 — at worst a
far-past cutoff, which makes every destructive command a no-op rather than a
delete-everything. `-0` reads as negative zero, `-0.0 < 0` is `False`, and it is
accepted as zero, which is harmless and matches current behavior for `0`.

Then extend `keiro-ops/test/Main.hs` `describe "parseDuration"` with the matrix in
Validation and Acceptance.

### Milestone 2 — close the sibling holes in the integer readers

Scope: eliminate the three unguarded `option auto` call sites and the silent
`Read Int` wraparound in every guarded reader, consolidating exact duplicates. At the
end of this milestone no keiro-ops flag parses a number without a bounds- and
sign-checked reader, proven by pure command-tree specs. Acceptance:
`cabal test keiro-ops-test` passes including the new `execParserPure` specs.

In `keiro-ops/src/Keiro/Ops/Parse.hs`, add and export:

```haskell
-- | Parse an integer via unbounded Integer and admit it only if it fits the
-- target type's bounds. Read at a bounded type silently wraps modulo 2^64
-- (read "18446744073709551716" :: Int is 100), which this prevents.
readBoundedIntegral :: forall a. (Integral a, Bounded a) => String -> Maybe a
readBoundedIntegral raw =
  case reads raw :: [(Integer, String)] of
    [(value, "")]
      | value >= toInteger (minBound :: a),
        value <= toInteger (maxBound :: a) ->
          Just (fromInteger value)
    _ -> Nothing

positiveIntReader :: ReadM Int
positiveIntReader = eitherReader $ \raw ->
  case readBoundedIntegral raw of
    Just n | n > 0 -> Right n
    _ -> Left "expected a positive integer"

nonNegativeIntReader :: ReadM Int
nonNegativeIntReader = eitherReader $ \raw ->
  case readBoundedIntegral raw of
    Just n | n >= 0 -> Right n
    _ -> Left "expected a non-negative integer"
```

(`GHC2024` is the default language for the package, so the `forall` with
`ScopedTypeVariables` compiles as written.)

Then, module by module:

- Delete the local `positiveIntReader` copies in `Inbox.hs` (lines 87–91),
  `Outbox.hs` (105–109), `Pgmq.hs` (69–73), `ReplayAudit.hs` (66–70), `Stream.hs`
  (111–115), `Timer.hs` (129–133), `Workflow.hs` (243–247) and the local
  `nonNegativeIntReader` copies in `Snapshot.hs` (86–90), `Stream.hs` (117–121),
  `Timer.hs` (123–127); import both from `Keiro.Ops.Parse` instead (several modules
  already import `durationReader` from it).
- Keep the domain-message readers module-local but change their `case reads raw of`
  scrutinee to `readBoundedIntegral raw` (adding the `Keiro.Ops.Parse` import),
  preserving each message verbatim: `nonNegativeInt64Reader` and
  `positiveInt32Reader` in `Rebuild.hs`, `nonNegativeInt64Reader` in `Snapshot.hs`
  and `Stream.hs`, `int64Reader` in `Pgmq.hs`, `generationReader` in `Workflow.hs`.
- Replace the three `option auto` call sites: `Workflow.hs` line 175
  (`wf list --limit`) and line 216 (`wf gc run-once --batch`) become
  `option positiveIntReader`; `ReplayAudit.hs` line 53 (`--resume-from`) gets a
  local `nonNegativeInt64Reader` built on `readBoundedIntegral` with message
  `expected a non-negative global position` (matching `Rebuild.hs`), since a
  `GlobalPosition` is a non-negative `Int64`.

Add the pure command-tree specs from Validation and Acceptance to
`keiro-ops/test/Main.hs` (they need no database, so they sit outside any `around`
block, like the existing "embedded command tree" describe).

### Milestone 3 — executable-level proof and closeout

Scope: prove at the process boundary that a `NaN` duration is refused before any
preview or database contact, run the whole suite, and update the living documents.
Acceptance: the new executable test passes against an unreachable database URL;
`cabal test keiro-ops-test` is fully green; MasterPlan 37's EP-5 progress line is
checked and its registry row moves to Complete; the ADR distillation pass is done.

Add to `keiro-ops/test/Main.hs` a describe block that does not use the database
fixture (place it near the existing `describe "keiro-ops executable"`):

```haskell
describe "keiro-ops numeric argument rejection" do
  it "refuses a NaN duration before any preview or database contact" do
    executable <- keiroOpsExecutable
    (exit, _, errText) <-
      readProcessWithExitCode
        executable
        [ "--database-url",
          "postgresql://nobody@127.0.0.1:1/unreachable",
          "outbox",
          "gc-sent",
          "--older-than",
          "NaN"
        ]
        ""
    exit `shouldBe` ExitFailure 2
    errText `shouldSatisfy` Text.isInfixOf "invalid duration \"NaN\"" . Text.pack
    errText `shouldSatisfy` not . Text.isInfixOf "preview only" . Text.pack
    errText `shouldSatisfy` not . Text.isInfixOf "schema verification" . Text.pack
```

The deliberately unreachable `--database-url` (port 1 refuses immediately, so nothing
hangs) is the proof of ordering: had parsing succeeded, the process would have
attempted schema verification and failed with a "schema verification failed" message
and exit code 1 (the `operationalFailure` path in `keiro-ops/src/Keiro/Ops.hs`);
instead optparse-applicative rejects the argument, prints the reader's message
(prefixed with the option name) plus usage, and exits with the command tree's
`failureCode 2` — before `runInvocation` runs at all.

For the ADR distillation pass required before marking this plan complete: add one
consequence bullet to
`docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`
recording that destructive numeric parameters are validated at parse time — a
preview computed from an unrepresentable cutoff is treated as a lie, so non-finite,
negative, and timestamptz-unrepresentable durations never reach the preview or
mutation phases. The wire-wrap mechanism and the frozen message texts stay here in
the plan (task-local detail).


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.

First, optionally demonstrate the defect before changing anything (safe: read-only
preview phase, but use a throwaway database if you run it against one; the pure test
below is safer). Then, for Milestone 1, write the new `parseDuration` unit specs
BEFORE editing `Parse.hs` and watch them fail:

```bash
cabal test keiro-ops-test --test-options='--match parseDuration'
```

Expected before the fix: failures such as
`parseDuration "NaN" ... expected: Left "invalid duration \"NaN\"..." but got: Right ...`.
Then edit `keiro-ops/src/Keiro/Ops/Parse.hs` as specified in Plan of Work and re-run;
expected after:

```text
Finished in ... seconds
N examples, 0 failures
```

For Milestone 2, apply the reader edits module by module, keeping the package
compiling as you go:

```bash
cabal build keiro-ops
cabal test keiro-ops-test --test-options='--match "numeric option rejection"'
```

For Milestone 3, run the executable-level test and then the whole suite (the suite
starts its own ephemeral PostgreSQL; expect a few minutes):

```bash
cabal test keiro-ops-test
```

Expected: `... examples, 0 failures` for the `keiro-ops-test` suite. Also demonstrate
the fix by hand, with no reachable database:

```bash
cabal run exe:keiro-ops -- --database-url 'postgresql://nobody@127.0.0.1:1/unreachable' outbox gc-sent --older-than NaN
echo "exit: $?"
```

Expected output (the first line is the load-bearing part; optparse prefixes the
message with the option name and appends usage text):

```text
option --older-than: invalid duration "NaN": expected a finite, non-negative number of seconds, optionally with an s, m, h, or d suffix

Usage: keiro-ops outbox gc-sent [--older-than DURATION]
...
exit: 2
```

Finally run the full repository Haskell gate the Justfile defines (optional but what
CI expects):

```bash
just haskell-verify
```

Commit per repository convention (Conventional Commits), for example
`fix(keiro-ops): reject non-finite and unrepresentable numeric CLI arguments`,
updating this plan's Progress section in the same commit at every stopping point.


## Validation and Acceptance

Acceptance is behavioral. After implementation, all of the following hold.

First, the duration parser: in `keiro-ops/test/Main.hs`, the extended
`describe "parseDuration"` block asserts this matrix and passes (the two `shouldBe`
string assertions freeze the operator-facing messages):

```haskell
it "rejects every non-finite spelling Read Double accepts" do
  parseDuration "NaN"
    `shouldBe` Left "invalid duration \"NaN\": expected a finite, non-negative number of seconds, optionally with an s, m, h, or d suffix"
  parseDuration "-NaN" `shouldSatisfy` isLeft
  parseDuration "Infinity" `shouldSatisfy` isLeft
  parseDuration "-Infinity" `shouldSatisfy` isLeft
  parseDuration "NaNs" `shouldSatisfy` isLeft
  parseDuration "NaNm" `shouldSatisfy` isLeft
  parseDuration "NaNh" `shouldSatisfy` isLeft
  parseDuration "NaNd" `shouldSatisfy` isLeft
  parseDuration "Infinityd" `shouldSatisfy` isLeft

it "rejects finite durations the timestamptz wire encoding cannot represent" do
  parseDuration "1e13"
    `shouldBe` Left "invalid duration \"1e13\": exceeds the maximum supported duration of 9.0e12 seconds (about 285000 years)"
  parseDuration "1e308" `shouldSatisfy` isLeft
  parseDuration "1e308d" `shouldSatisfy` isLeft
  parseDuration "115740741000000d" `shouldSatisfy` isLeft

it "still rejects lowercase non-finite spellings, negatives, and junk" do
  parseDuration "nan" `shouldSatisfy` isLeft
  parseDuration "infinity" `shouldSatisfy` isLeft
  parseDuration "-1" `shouldSatisfy` isLeft
  parseDuration "-1s" `shouldSatisfy` isLeft
  parseDuration "soon" `shouldSatisfy` isLeft
  parseDuration "" `shouldSatisfy` isLeft

it "accepts integers, decimals, scientific notation, and suffixes unchanged" do
  parseDuration "0" `shouldBe` Right 0
  parseDuration "1.5" `shouldBe` Right 1.5
  parseDuration "2592000" `shouldBe` Right 2592000
  parseDuration "1e6" `shouldBe` Right 1000000
  parseDuration "2m" `shouldBe` Right 120
  parseDuration "3h" `shouldBe` Right 10800
  parseDuration "30d" `shouldBe` Right 2592000
  parseDuration "9.0e12" `shouldBe` Right 9000000000000
```

(The existing specs at lines 200–209 — bare seconds, suffixes, `-1s`, `soon` — are
subsumed by this matrix and may be merged into it.)

Second, the command tree: a new pure describe block (no database) asserts, via the
existing `parseOps`/`isParseFailure`/`isParseSuccess` helpers with `embeddedHooks`:

```haskell
describe "numeric option rejection" do
  it "rejects non-finite durations on every duration flag" do
    isParseFailure (parseOps embeddedHooks ["outbox", "gc-sent", "--older-than", "NaN"]) `shouldBe` True
    isParseFailure (parseOps embeddedHooks ["outbox", "requeue-stuck", "--older-than", "Infinity"]) `shouldBe` True
    isParseFailure (parseOps embeddedHooks ["inbox", "gc", "--older-than", "NaN"]) `shouldBe` True
    isParseFailure (parseOps embeddedHooks ["timer", "stuck", "list", "--min-age", "NaNd"]) `shouldBe` True
    isParseFailure (parseOps embeddedHooks ["wf", "gc", "run-once", "--retention", "NaN", "--batch", "100"]) `shouldBe` True

  it "rejects non-positive and wrapped integer options at parse time" do
    isParseFailure (parseOps embeddedHooks ["wf", "gc", "run-once", "--retention", "30d", "--batch", "0"]) `shouldBe` True
    isParseFailure (parseOps embeddedHooks ["wf", "gc", "run-once", "--retention", "30d", "--batch", "-5"]) `shouldBe` True
    isParseFailure (parseOps embeddedHooks ["wf", "list", "--limit", "0"]) `shouldBe` True
    isParseFailure (parseOps embeddedHooks ["replay-audit", "--full", "--resume-from", "-1"]) `shouldBe` True
    isParseFailure (parseOps embeddedHooks ["outbox", "list", "--source", "s", "--limit", "18446744073709551716"]) `shouldBe` True
    isParseSuccess (parseOps embeddedHooks ["wf", "gc", "run-once", "--retention", "30d", "--batch", "100"]) `shouldBe` True
    isParseSuccess (parseOps embeddedHooks ["replay-audit", "--full", "--resume-from", "0"]) `shouldBe` True
```

(`--batch -5` passes `-5` as the option's argument under optparse-applicative's
option-argument rules; if the harness ever treats it as a flag, use the
`--batch=-5` single-token spelling — the assertion is the same.)

Third, the process boundary: the Milestone 3 executable test passes — exit code 2,
stderr contains `invalid duration "NaN"`, and contains neither `preview only` nor
`schema verification`, against an unreachable database URL, proving rejection
precedes both the preview phase and any database contact.

Fourth, no regression: `cabal test keiro-ops-test` (from the repository root) ends
with `0 failures`, including all pre-existing handler and executable tests — this
proves the accepted-form surface (`30d`, `5m`, `0s`, integer limits) is unchanged,
because those tests exercise the defaults and explicit durations throughout.

Interpreting failures: an exact-message mismatch in the two `shouldBe` string specs
means the implementation's message drifted from this plan — fix the code, not the
test, or record a Decision Log entry changing the frozen text. A failure of the
executable test with `exit: 1` and `schema verification failed` on stderr means
parsing did NOT reject the argument and the process reached the database layer — the
Milestone 1 guard is wrong or the flag under test is not wired to `durationReader`.


## Idempotence and Recovery

Every step is a pure source edit plus a test run: repeatable without damage or
drift. No migrations, no schema changes, no data operations, and no dependency or
version changes are involved. `cabal test keiro-ops-test` can be re-run any number
of times; its ephemeral PostgreSQL is created and destroyed by the suite fixture.
If work stops partway through Milestone 2, the package may fail to compile because a
module still references a deleted local reader — recovery is to finish that module's
import switch or restore the local copy; each module's edit is independent, so
modules can be converted and committed one at a time. The manual demonstration
command uses a deliberately unreachable database URL and mutates nothing even if run
against a real deployment's environment. Do not run `outbox gc-sent --older-than NaN
--force` against any real database to "demonstrate the bug" — the pre-fix behavior
is verified by the unit matrix instead.


## Interfaces and Dependencies

No new packages. The work uses only existing dependencies of `keiro-ops`:
`optparse-applicative` (the `ReadM`/`eitherReader` reader machinery), `time`
(`NominalDiffTime`), `base` (`Text.Read.readMaybe`, `isNaN`, `isInfinite`), and, in
tests, `hspec`, `process` (`readProcessWithExitCode`), and `text`. The hasql /
postgresql-binary wire behavior documented here is context, not a code dependency of
this change — no library code is edited.

At the end of Milestone 1, `keiro-ops/src/Keiro/Ops/Parse.hs` still exports exactly
`durationReader :: ReadM NominalDiffTime` and
`parseDuration :: String -> Either String NominalDiffTime`, with the new internal
constant `maxDurationSeconds :: Double` (9.0e12).

At the end of Milestone 2, `Keiro.Ops.Parse` exports additionally:

```haskell
readBoundedIntegral :: (Integral a, Bounded a) => String -> Maybe a
positiveIntReader :: ReadM Int
nonNegativeIntReader :: ReadM Int
```

and no command module retains a local `positiveIntReader` or `nonNegativeIntReader`;
the module-local domain readers (`nonNegativeInt64Reader` in `Rebuild.hs`,
`Snapshot.hs`, `Stream.hs`, and newly `ReplayAudit.hs`; `positiveInt32Reader` in
`Rebuild.hs`; `int64Reader` in `Pgmq.hs`; `generationReader` in `Workflow.hs`) are
implemented over `readBoundedIntegral` with their existing signatures and error
messages. No handler signature, command name, flag name, default value, JSON output
shape, or exit-code contract changes anywhere in the package — the only behavioral
change is which argument strings are rejected at parse time.
