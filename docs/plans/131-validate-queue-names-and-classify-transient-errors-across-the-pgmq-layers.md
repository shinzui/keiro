---
id: 131
slug: validate-queue-names-and-classify-transient-errors-across-the-pgmq-layers
title: "Validate queue names and classify transient errors across the pgmq layers"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/21-harden-the-pgmq-hs-family-surfaced-by-the-2026-07-pgmq-hs-review.md"
---

# Validate queue names and classify transient errors across the pgmq layers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Three input/classification defects in the pgmq-hs family (the Haskell client stack for
PGMQ, the PostgreSQL Message Queue, at
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`) let bad inputs and
mis-labeled errors slip through the typed surface. First (PGH-7): the Haskell validator
`parseQueueName` accepts uppercase letters while the SQL layer lowercases physical table
names and stores the original casing in metadata — so `MyQueue` and `myqueue` are two
logical queues sharing ONE physical table (interleaved messages; dropping one destroys the
other's data), and enabling insert notifications on `MyQueue` writes a throttle row the
trigger can never match, silently killing notify. Worse, `QueueName`'s `FromJSON` instance
is newtype-derived, so config-loaded names bypass validation entirely (any string of any
length). Second (PGH-10): `isTransient` — the retry-classification predicate that
shibuya-pgmq-adapter's retry loops call on every failed ack/poll — classifies every
server-reported statement error as permanent, including serialization failures (40001),
deadlocks (40P01), lock timeouts (55P03), admin shutdown (57P01), and resource exhaustion
(53xxx), all of which arrive as `StatementSessionError` and all of which are precisely the
errors retries exist for. Third (PGH-11): the message decoder requires a non-null body, but
the `message` column is nullable and `pgmq.send(queue, NULL::jsonb)` is legal SQL — one
NULL-bodied row inserted by any non-Haskell producer makes EVERY read batch containing it
fail at decode, after the read statement has already bumped `vt`/`read_ct` for the whole
batch: an unidentifiable poison row that cannot even be seen from the Haskell side.

After this plan: uppercase (and empty) queue names are rejected at both entry paths
(`parseQueueName` and `FromJSON`); the transient SQLSTATEs classify as transient and are
pinned by tests; and a NULL body decodes as JSON `null`, so the poison row is readable,
identifiable, and archivable through the normal API. This plan is also the expected LAST
lander of the shared family release train, so it carries the consumer bound bumps and
consumer suite runs.


## Progress

- [ ] M1 (repro/evidence): raw-SQL aliasing tests demonstrate consequences (a) and (b)
      live (silent notify miss for `MyQueue`; one physical table, two meta rows,
      cross-destruction on drop); `FromJSON`/`parseQueueName` rejection tests written and
      red; NULL-body poison test written and red (whole-batch decode failure with
      `read_ct` already bumped); classification tests for the transient SQLSTATEs written
      and red. Transcripts recorded in Surprises & Discoveries.
- [ ] M2 (fix): `parseQueueName` rejects uppercase and empty; `FromJSON QueueName`
      validates via `parseQueueName`; new `pgmq-core-test` suite green; `isTransient`
      whitelists 40001/40P01/55P03/57P01/53xxx inside `StatementSessionError`;
      `messageDecoder` maps SQL NULL to JSON null; all M1 tests green; mixed-case
      migration note written (below, in Plan of Work M2).
- [ ] M3 (release train, only if this plan lands last — else transfer and record): family
      version verified and consumer bounds bumped in `keiro-pgmq.cabal` and
      `shibuya-pgmq-adapter.cabal`; shibuya `leaseExtend` adjusted for plan 129's
      `Maybe Message`; keiro suite green at its 58/0/2 baseline; shibuya suite green.
- [ ] CHANGELOG entry; living sections updated; ADR distillation pass (queue-name
      validation contract; transient classification whitelist) into keiro's `docs/adr/`.


## Surprises & Discoveries

Seeded from the 2026-07 pgmq-hs review (2026-07-23; PGH-7 and PGH-10 confirmed by code
reading; PGH-11 decode-throw certain from the decoder, reachability via any non-Haskell
producer):

- The SQL layer itself is consistent-by-lowercasing (`format_table_name` lowercases,
  install SQL line 244) but `pgmq.meta` stores the caller's original casing (lines
  1145-1151, `INSERT ... VALUES (%L, ...)` with the raw name) and the notify trigger
  extracts the LOWERCASED name from the physical table (line 1572) — three views of one
  name that only agree for lowercase input.
- The per-queue advisory lock hashes the RAW name (`hashtext('pgmq.queue_' ||
  queue_name)`, line 113), so `MyQueue` and `myqueue` do not even serialize against each
  other while mutating the same physical table — one more aliasing artifact that
  rejection at the source removes.
- hasql (pinned 1.10.3.5 via cabal.project source-repository-package) names the
  row-count decode failure `UnexpectedRowCountStatementError` (older hasql called it
  "UnexpectedAmountOfRows"); the SQLSTATE for a server error is the first field of
  `ServerError` inside `ServerStatementError` inside the six-field
  `StatementSessionError`.

(Add new discoveries below as work proceeds.)


## Decision Log

- Decision: REJECT uppercase queue names in `parseQueueName` (lowercase ASCII letters,
  digits, underscore only) rather than silently normalizing to lowercase.
  Rationale: Normalization re-introduces aliasing against pre-existing mixed-case meta
  rows (a normalized `MyQueue` would silently join a previously-created `myqueue`'s
  physical table while a `MyQueue` meta row still exists), and it makes
  `queueNameToText` disagree with what the caller wrote — invisible behavior. Rejection
  is loud, at the boundary, and matches the smart-constructor design the type already
  has (the `QueueName` constructor is unexported). A migration note for existing
  uppercase meta rows is mandatory (see M2) because the stricter parser makes such rows
  fail `listQueues` decoding (`queueDecoder` runs `parseQueueName` via `D.refine`,
  `pgmq-hasql/src/Pgmq/Hasql/Decoders.hs` line 62).
  Date: 2026-07-23

- Decision: Also reject the empty string in `parseQueueName` (it passes both current
  checks and would produce the physical table `q_`).
  Rationale: Same boundary, same fix, zero legitimate use; verified no caller constructs
  an empty name.
  Date: 2026-07-23

- Decision: `FromJSON QueueName` becomes a hand-written instance that runs
  `parseQueueName` (via `Aeson.withText`), replacing the newtype-derived instance.
  `ToJSON` stays derived. The same derived-`FromJSON` bypass exists on `RoutingKey` and
  `TopicPattern` (`pgmq-core/src/Pgmq/Types.hs` lines 111 and 129) — noted as an
  adjacent hazard, deliberately OUT of this plan's scope (no finding filed; record for a
  follow-up).
  Date: 2026-07-23

- Decision: Transient SQLSTATE whitelist inside `StatementSessionError`: exactly
  `40001` (serialization_failure), `40P01` (deadlock_detected), `55P03`
  (lock_not_available), `57P01` (admin_shutdown), and the `53` class prefix
  (insufficient resources: 53000/53100/53200/53300/53400). Everything else in
  `StatementSessionError` — other server errors, row-count/column/decode errors —
  remains permanent.
  Rationale: These five are the canonical retry-worthy states; 40P01 is genuinely
  reachable here (overlapping batch delete/archive statements lock message rows in
  statement-internal order, so two sessions finalizing overlapping id sets can
  deadlock). The existing `ClassificationSpec` deliberately did not pin the
  `StatementSessionError` case; now it pins both directions.
  Date: 2026-07-23

- Decision: Decode a NULL `message` column as JSON `null` (`MessageBody
  Data.Aeson.Null`) rather than changing `Message.body` to `Maybe MessageBody` or
  documenting single-client ownership.
  Rationale: The mapping is API-compatible (no consumer breakage beyond plan 129's
  already-breaking release), and it surfaces the poison row to the consumer, who can
  see it (`body == MessageBody Null`), route it, and dead-letter/archive it through the
  normal API. Accepted conflation, recorded here: after this change a SQL NULL body and
  an explicitly-sent JSON `null` body are indistinguishable on read — which is the
  honest merged semantics, since both mean "no usable payload". "Document single-client
  ownership" was rejected because the queue tables are plain SQL any producer can
  write to; a doc cannot un-arm the trap.
  Date: 2026-07-23

- Decision: This plan carries the last-lander duties of the shared release train
  (consumer bound bumps + consumer suites) as milestone M3, conditional on it actually
  landing last. If plan 129 or 130 lands after this one, M3 transfers to it verbatim;
  record the transfer in both plans' Decision Logs.
  Date: 2026-07-23

(Record further decisions as they are made, with dates.)


## Outcomes & Retrospective

(To be filled during and after implementation. Before completion, promote the queue-name
validation contract and the transient-classification whitelist into `docs/adr/`.)


## Context and Orientation

Work happens in `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`
(cabal multi-package project; ignore `dist-newstyle/`; run commands from that directory
inside `nix develop`, which provides ghc 9.12.4, cabal, and the PostgreSQL binaries the
tests need). Consumer repos touched only in M3: the keiro monorepo at
`/Users/shinzui/Keikaku/bokuno/keiro` (package `keiro-pgmq`) and shibuya's adapter at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter` (package
`shibuya-pgmq-adapter`).

Relevant ADR: keiro's `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` —
tangentially relevant. It pins the traced pgmq-effectful interpreter's span semantics;
this plan changes error *classification* (`isTransient`) but must not change what the
traced interpreter emits. That holds by construction: `isTransient` is a pure predicate
consumers call on an already-surfaced error; the traced interpreter's error labeling
(`errorStatusDescription`, `pgmq-effectful/src/Pgmq/Effectful/Interpreter/Traced.hs`
lines 498-516) is untouched. Both interpreters surface the same `PgmqRuntimeError` via
`fromUsageError`, and `isTransient` is a single shared function — so plain/traced parity
is structural, not something to re-implement. No pgmq-hs-repo ADR exists.

Exact locations of the three defects (verify each before editing; if a line drifted,
find the construct by name and update this plan):

**PGH-7 — queue-name aliasing.** `parseQueueName`
(`pgmq-core/src/Pgmq/Types.hs` lines 91-99) accepts any ASCII alphanumeric plus
underscore (`isValidChar c = (isAscii c && isAlphaNum c) || c == '_'`, line 99), max
length 47 (63-character PostgreSQL identifier limit minus the longest prefix
`archived_at_idx_`, lines 101-105). The SQL side lowercases physical names
(`pgmq.format_table_name`, install SQL
`pgmq-migration/migrations/0001-install-v1.11.0.sql` line 244: `RETURN lower(prefix ||
'_' || queue_name)`) but `pgmq.create` stores the ORIGINAL casing in `pgmq.meta` (lines
1145-1151), and the notify trigger extracts the lowercased name from the table name
(line 1572). Consequences: (a) `enable_notify_insert('MyQueue')` inserts throttle row
`'MyQueue'` but the trigger looks up `'myqueue'` — the throttle UPDATE matches nothing
and no notification ever fires, silently; (b) `create('MyQueue')` then
`create('myqueue')` yields ONE physical table `q_myqueue` (both creates are `CREATE
TABLE IF NOT EXISTS`) with TWO meta rows — sends and reads interleave between "both"
queues, and `drop_queue('myqueue')` destroys the other's messages; (c) `QueueName`
derives `FromJSON` newtype-style (`Types.hs` lines 73-74), so JSON/config-loaded names
skip length and charset checks entirely. The `QueueName` data constructor is not
exported (export list lines 3-25 export only the type, `parseQueueName`,
`queueNameToText`), so `parseQueueName`, `FromJSON`, and the `Lift` instance (compile
time only) are the complete set of entry paths. Also relevant: `queueDecoder`
re-validates names read back from the database through `parseQueueName`
(`pgmq-hasql/src/Pgmq/Hasql/Decoders.hs` line 62, `D.refine`), which is what makes the
stricter parser a migration concern for existing uppercase meta rows (see M2).

**PGH-10 — transient errors classified permanent.** `isTransient`
(`pgmq-effectful/src/Pgmq/Effectful/Interpreter.hs` lines 65-78) maps
`HasqlErrors.StatementSessionError {} -> False` unconditionally (line 75). But
serialization failures, deadlocks, lock timeouts, shutdowns, and resource exhaustion
all arrive as server errors inside `StatementSessionError`. The hasql error shape
(pinned hasql 1.10.3.5; source
`/Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql/src/library/Hasql/Errors.hs`,
which re-exports `Hasql.Engine.Errors`): `StatementSessionError Int Int Text [Text]
Bool StatementError` (total statements, index, SQL, params, prepared, error), where
`StatementError` includes `ServerStatementError ServerError` and `ServerError`'s first
field is the five-character SQLSTATE code as `Text`. All constructors are exported from
`Hasql.Errors`. The existing `pgmq-effectful/test/ClassificationSpec.hs` pins every
case EXCEPT `StatementSessionError` — deliberately, awaiting this decision. Consumer
reality (verified 2026-07-23): keiro-pgmq does NOT call `isTransient` anywhere (grep:
zero hits) — this fix is for direct consumers; shibuya-pgmq-adapter IS one — it imports
`isTransient` (`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs` line 62) and
gates every ack/poll retry on it (`retryingTransient`, lines 506-515), so after the
family bump its retry loops start actually retrying deadlocks and serialization
failures instead of failing fast.

**PGH-11 — NULL body poisons every batch.** `messageDecoder` requires a non-null body
(`pgmq-hasql/src/Pgmq/Hasql/Decoders.hs` line 51: `MessageBody <$> D.column
(D.nonNullable D.jsonb)`), but the queue table's `message` column is nullable (install
SQL line 1106) and `SELECT pgmq.send('q', NULL::jsonb)` is legal. Any non-Haskell
producer (psql, another language's client, a trigger) can insert a NULL body; every
subsequent `read`/`readWithPoll`/`pop` batch containing that row fails at decode —
AFTER the read's UPDATE already bumped `vt` and `read_ct` for the entire batch (the
statement succeeded; decoding its result failed). The row cannot be seen, read, or
archived through the Haskell client, and it re-poisons every batch each time its
visibility timeout lapses.

Test infrastructure (same as the sibling plans): every pgmq-hs suite self-provisions
PostgreSQL via the `ephemeral-pg` library — each package's `test/EphemeralDb.hs` starts
a cached temp server, applies the full migration ledger through pg-migrate, and hands
the suite a hasql-pool `Pool`. No external database or env vars. `pgmq-core` currently
has NO test suite (its `.cabal` defines only the library); M2 adds one. Suites are
tasty-based; DB-backed specs take the shared `Pool` (see
`pgmq-hasql/test/Main.hs` and helpers in `pgmq-hasql/test/TestUtils.hs`:
`assertSession`, `runSession`, `assertSessionFails`, `withTestFixture`).


## Plan of Work

### Milestone 1 — evidence and red tests

Scope: demonstrate all three defects inside this repo's test harness before fixing
anything. Nothing under any `src/` changes. What exists at the end: three new/extended
test modules whose failures (and raw-SQL evidence) are captured in Surprises &
Discoveries.

`pgmq-hasql/test/AliasingSpec.hs` (register in `pgmq-hasql.cabal` `other-modules` and
`test/Main.hs`): drive the SQL layer directly with `Hasql.Session.sql` /
`Hasql.Session.statement` raw statements so the tests remain valid after the Haskell
parser tightens (uppercase names will then be unconstructible through the API — which
is the point). Use a random suffix as the existing fixtures do, e.g. `MyQueue_<n>` /
`myqueue_<n>`. Cases, in prose: create both casings via `select pgmq.create(...)`;
assert exactly ONE physical table exists
(`select count(*) from information_schema.tables where table_schema='pgmq' and
table_name='q_myqueue_<n>'` equals 1 and no `q_MyQueue_<n>` variant) while `pgmq.meta`
holds TWO rows for the pair; send via the uppercase name and read via the lowercase one
to show interleaving; `select pgmq.drop_queue('myqueue_<n>')` and assert the uppercase
alias is now broken (a subsequent send through it errors — its meta row survives but
the table is gone). For consequence (a): create + `select
pgmq.enable_notify_insert('MyQueue_<n>', 0)`, send a message, and assert the throttle
row's `last_notified_at` is still the epoch (`to_timestamp(0)`) — the trigger looked up
the lowercase name, found nothing, and (today) suppressed the notification silently.
These are evidence tests: they PASS against current code and stay green after M2 (the
SQL layer is out of scope; the Haskell boundary is the fix). Label them clearly as
documenting why rejection matters.

`pgmq-core` rejection tests: because pgmq-core has no suite yet, write these as part of
the new suite you will register in M2 but run them now against unfixed code to record
the red state — or simply note that `parseQueueName "MyQueue"` currently returns
`Right` by evaluating it in `cabal repl pgmq-core`. Target assertions (red today):
`parseQueueName "MyQueue"` is `Left (InvalidQueueName ...)`; `parseQueueName ""` is
`Left`; `Aeson.fromJSON (Aeson.String "MyQueue") :: Result QueueName` is `Error`;
same for a 60-character and a hyphenated string via FromJSON (today ALL of these
succeed through FromJSON — the bypass).

`pgmq-hasql/test/NullBodySpec.hs`: create a queue, send two well-formed messages via
`Sessions.sendMessage`, then insert the poison via raw SQL (`Hasql.Session.sql` with
the queue name spliced — safe here, names are `[a-z0-9_]`):
`select pgmq.send('<qname>', null::jsonb)`. Red assertions against current code:
`Sessions.readMessage` with `batchSize = Just 10` fails the session (decode error on
the NULL cell), and — the poison property — a raw
`select read_ct from pgmq.q_<qname>` shows `read_ct` bumped to 1 on ALL THREE rows even
though the Haskell call failed. Write the M2 target assertions alongside, commented or
behind the fix.

`pgmq-effectful/test/ClassificationSpec.hs`: extend with a helper that builds
`PgmqSessionError (StatementSessionError 1 0 "select 1" [] True (ServerStatementError
(ServerError code "boom" Nothing Nothing Nothing)))` for a given `code`, then assert
transient for `"40001"`, `"40P01"`, `"55P03"`, `"57P01"`, `"53100"`, `"53200"`,
`"53300"`, and permanent for `"23505"` (unique violation), `"42P01"` (undefined table),
`"22P02"` (bad text representation), plus permanent for a non-server statement error
(`UnexpectedRowCountStatementError 1 1 0`). All red today (every one currently
classifies permanent, so the transient assertions fail).

Acceptance: `cabal test pgmq-hasql-test pgmq-effectful-test --test-show-details=direct`
shows the predicted failures; AliasingSpec passes (it is evidence, not a fix gate);
transcripts pasted into Surprises & Discoveries.

### Milestone 2 — the fixes and the new pgmq-core suite

Scope: three small source changes plus a new test suite; every M1 red test goes green.

`pgmq-core/src/Pgmq/Types.hs`:

- `parseQueueName` (lines 91-99): reject empty and uppercase. Replace the guards with
  an added emptiness check and change the character predicate to lowercase-only:

```haskell
parseQueueName :: Text -> Either PgmqError QueueName
parseQueueName t
  | T.null t = Left $ InvalidQueueName "The queue name is empty."
  | not isShortEnough = Left $ InvalidQueueName "The queue name is too long."
  | not hasValidCharacters =
      Left $
        InvalidQueueName
          "The queue name contains invalid characters (allowed: lowercase ASCII letters, digits, underscore)."
  | otherwise = Right $ QueueName t
  where
    isShortEnough = T.length t <= maxQueueNameLength
    hasValidCharacters = T.all isValidChar t
    isValidChar c = (isAscii c && (isLower c || isDigit c)) || c == '_'
```

  Adjust the `Data.Char` import (line 29) to `(isAscii, isDigit, isLower)`. Keep the
  length machinery (lines 101-105) untouched. Update the haddock to state the contract
  and WHY: SQL `format_table_name` lowercases physical names while `pgmq.meta` stores
  the original casing, so mixed-case names alias one physical table under two
  identities; lowercase-only input makes all three representations agree.

- `FromJSON QueueName`: remove `FromJSON` from the deriving-newtype list (line 74,
  keeping `Eq, Ord, ToJSON`) and add:

```haskell
instance FromJSON QueueName where
  parseJSON = Aeson.withText "QueueName" $ \t ->
    either (fail . show) pure (parseQueueName t)
```

  with `import Data.Aeson qualified as Aeson` added (the module currently imports only
  the classes). `PgmqError` already derives `Show`.

New suite: add to `pgmq-core/pgmq-core.cabal` a `test-suite pgmq-core-test`
(exitcode-stdio-1.0, `hs-source-dirs: test`, `main-is: Main.hs`; build-depends: base,
aeson, pgmq-core, tasty ^>=1.5, tasty-hunit ^>=0.10, text — mirror the warnings import
and GHC2024 defaults the other suites use). `pgmq-core/test/Main.hs` runs a
`QueueNameSpec` covering: acceptance (`"my_queue_123"`, a 47-char lowercase name);
rejection with the right `InvalidQueueName` message for `"MyQueue"`, `""`, a 48-char
name, `"bad-name"`, `"queue!"`; and the FromJSON path — `Aeson.fromJSON (Aeson.String
"myqueue")` succeeds and round-trips through `ToJSON`, while `"MyQueue"`, `""`, and an
overlong string produce `Aeson.Error`. Also add the wired-in cabal.project entry: none
needed — `pgmq-core` is already a project package, and `cabal test all` picks up the
new suite automatically.

Migration note (write this, verbatim or improved, into the CHANGELOG entry and the
`parseQueueName` haddock — it is the operational half of the reject decision): after
upgrading, a database that already contains mixed-case rows in `pgmq.meta` will fail
`listQueues` decoding (and therefore pgmq-config reconciliation, which lists queues
first) because names read back through `queueDecoder` are re-validated. Detect with
`SELECT queue_name FROM pgmq.meta WHERE queue_name <> lower(queue_name);`. Remediate
BEFORE upgrading: for each such row, if a lowercase twin exists the two are aliases of
one physical table — pick the lowercase row and delete the uppercase one (`DELETE FROM
pgmq.meta WHERE queue_name = '<Mixed>'`; note `pgmq.notify_insert_throttle` references
`meta` with ON DELETE CASCADE, and the FK has no ON UPDATE action, so disable notify
for the affected queue first if a throttle row exists under the mixed-case name); if no
twin exists, `UPDATE pgmq.meta SET queue_name = lower(queue_name) WHERE queue_name =
'<Mixed>'` (again after clearing any throttle row under the old name, then re-enable).
As of 2026-07-23 no registered consumer creates mixed-case names (the exposure is
latent) — verify that is still true against the deployed databases before releasing.

`pgmq-effectful/src/Pgmq/Effectful/Interpreter.hs`:

- Rewrite the `PgmqSessionError` branch of `isTransient` (lines 65-78):

```haskell
  PgmqSessionError e -> case e of
    HasqlErrors.ConnectionSessionError _ -> True
    HasqlErrors.StatementSessionError _ _ _ _ _ statementError ->
      case statementError of
        HasqlErrors.ServerStatementError (HasqlErrors.ServerError code _ _ _ _) ->
          isTransientSqlState code
        _ -> False
    HasqlErrors.ScriptSessionError {} -> False
    HasqlErrors.MissingTypesSessionError _ -> False
    HasqlErrors.DriverSessionError _ -> False

-- | SQLSTATEs that indicate a transient, retry-worthy condition:
-- 40001 serialization_failure, 40P01 deadlock_detected, 55P03
-- lock_not_available, 57P01 admin_shutdown, and class 53 (insufficient
-- resources). Everything else reported by the server is permanent for
-- retry purposes.
isTransientSqlState :: Text -> Bool
isTransientSqlState code =
  code `elem` ["40001", "40P01", "55P03", "57P01"] || "53" `T.isPrefixOf` code
```

  Add `import Data.Text (Text)` / `import Data.Text qualified as T` as needed (the
  module has no text import today; `text` is already a pgmq-effectful dependency).
  Update the `isTransient` haddock (lines 53-60 region) to name the whitelist. Do not
  export `isTransientSqlState` unless a test needs it — the ClassificationSpec tests go
  through `isTransient` itself. No traced-interpreter change: parity is structural (one
  shared predicate over one shared error type; see Context).

`pgmq-hasql/src/Pgmq/Hasql/Decoders.hs`:

- `messageDecoder` line 51: change the body column to nullable-with-null-mapping:

```haskell
    <*> (MessageBody . fromMaybe Aeson.Null <$> D.column (D.nullable D.jsonb)) -- message
```

  Add `import Data.Aeson qualified as Aeson` and `import Data.Maybe (fromMaybe)`
  (aeson is already a pgmq-hasql dependency). Haddock the mapping and the conflation:
  SQL NULL and JSON null both surface as `MessageBody Aeson.Null`.

Then finalize the M1 tests: `NullBodySpec`'s target assertions — `readMessage` with
`Just 10` now returns all three rows; exactly one has `body == MessageBody Aeson.Null`;
`Sessions.archiveMessage` succeeds on it; a follow-up read (after vt expiry or with a
fresh send) contains no poison. ClassificationSpec's transient assertions now pass.
pgmq-core-test passes.

Acceptance: `cabal test all --test-show-details=direct` green from the pgmq-hs root,
including the brand-new `pgmq-core-test`. AliasingSpec still green (unchanged SQL-layer
behavior, now unreachable from validated Haskell input).

### Milestone 3 — release-train close-out (last lander only)

Scope: only execute if this plan is the last of the train (plans 116, 118, 129, 130,
131) to land; otherwise transfer this milestone verbatim to the actual last lander and
record the transfer in both Decision Logs. At the end, both consumer repos build and
test green against the released family.

The family release is expected to be **0.5.0.0** (plan 129's `Maybe Message` result
types are PVP-major; plans 116/118 planned 0.4.1.0/0.4.2.0 for their SQL-only changes —
if everything ships as one coordinated release, it is one 0.5.0.0). Verify the actually
released/served version before writing any bound (check the five `.cabal` `version:`
fields on the release commit and how consumers pin the family — keiro consumes it via
its nix flake inputs; see keiro commit `ef0b246` for the previous family bump shape —
and, per the mori guidance in the user's global instructions, confirm against the
authoritative registry rather than assuming).

1. In `/Users/shinzui/Keikaku/bokuno/keiro/keiro-pgmq/keiro-pgmq.cabal`, raise the
   library bounds (lines 62-65: `pgmq-config`, `pgmq-core`, `pgmq-effectful`,
   `pgmq-hasql`, all `>=0.4 && <0.5` today) and the test-suite bounds (lines 92-95,
   including `pgmq-migration >=0.4 && <0.5` — which plans 116/118 may already have
   raised to `>=0.4.1`/`>=0.4.2`) to the released version, e.g. `>=0.5 && <0.6`.
2. In `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`,
   raise lines 49-51 (`pgmq-core`/`pgmq-effectful`/`pgmq-hasql ^>=0.4`) to `^>=0.5`.
3. Apply the one consumer code change plan 129's break requires:
   `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs` lines 198-206 —
   `setVisibilityTimeoutAt` now returns `Maybe Message`, so replace
   `liftIO $ writeIORef lastVtRef updated.visibilityTime` with a traversal, e.g.
   `liftIO $ for_ updated $ \m -> writeIORef lastVtRef m.visibilityTime`
   (`Data.Foldable (for_)`) — a raced-away message during lease extension leaves the
   last-VT tracking unchanged, which is the correct semantics (the message is gone).
   keiro-pgmq needs NO code change: its three `changeVisibilityTimeout` call sites
   (`keiro-pgmq/src/Keiro/PGMQ/Job.hs` lines 994, 1018, 1042) all discard the result
   with `void`.
4. Run both consumer suites and compare to baseline:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal test keiro-pgmq-test --test-show-details=direct
# baseline before this train: 58 examples, 0 failures, 2 pending — expect the same

cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
just test   # = cabal test shibuya-pgmq-adapter-test --enable-tests
```

Acceptance: both suites green (keiro at its 58/0/2 baseline); bounds and the shibuya
fix committed in their own repos (conventional commits; this plan only records the
outcome — do not edit the master plan).


## Concrete Steps

pgmq-hs work, from `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`
inside `nix develop`:

```bash
cd /Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs

# M1: add AliasingSpec + NullBodySpec (pgmq-hasql), extend ClassificationSpec
cabal test pgmq-hasql-test --test-show-details=direct
cabal test pgmq-effectful-test --test-show-details=direct

# M2: edit pgmq-core/src/Pgmq/Types.hs, pgmq-effectful Interpreter.hs,
#     pgmq-hasql Decoders.hs; add pgmq-core test suite
cabal build all
cabal test all --test-show-details=direct
```

Expected transcript shapes:

```text
# M1 (red)
ClassificationSpec
  40P01 deadlock is transient:            FAIL (expected transient)
NullBodySpec
  batch containing NULL body reads fully: FAIL
    Session failed: ... StatementSessionError ... Unexpected null value ...
  poison row bumped read_ct anyway:       OK   (evidence)

# M2 (green)
pgmq-core-test
  parseQueueName rejects "MyQueue":       OK
  FromJSON rejects unvalidated names:     OK
ClassificationSpec:                       all OK
NullBodySpec:                             all OK
```

M3 commands are inline in the milestone above (they run in the two consumer repos).


## Validation and Acceptance

A novice can verify each half independently. Queue names: `cabal test pgmq-core-test`
shows `parseQueueName` and `FromJSON` rejecting `"MyQueue"`, `""`, overlong and
bad-charset names while accepting lowercase names, and `cabal repl pgmq-core` confirms
`parseQueueName "MyQueue"` is a `Left`; the pgmq-hasql `AliasingSpec` documents, live
against PostgreSQL, exactly what those rejections prevent (one physical table behind
two meta identities; the silent notify miss; drop destroying the alias's messages).
Classification: `cabal test pgmq-effectful-test` pins 40001/40P01/55P03/57P01/53xxx as
transient and unique-violation/undefined-table/decode failures as permanent, all
through the public `isTransient`. Poison row: `cabal test pgmq-hasql-test` shows a
SQL-inserted NULL-body message being read (as JSON null) and archived through the
Haskell client — a sequence that failed at the read step before the fix, with the
before-state (whole-batch decode failure after `read_ct` was bumped) preserved in the
M1 transcript. Train close-out (M3, conditional): both consumer suites green at their
recorded baselines with the new bounds.


## Idempotence and Recovery

All pgmq-hs steps are re-runnable: test modules are additive; the three source edits
are idempotent replacements; no migration file and no database state are involved
(ephemeral databases are per-run). The one step with external effect is M3's bound
bumps in the two consumer repos — plain cabal edits, revertible with git, and gated on
the family release existing; if the release is re-cut, re-verify the version and re-run
both suites. If the stricter `parseQueueName` must be rolled back after release
(e.g. an unanticipated mixed-case deployment surfaces), the safe path is the documented
meta-row remediation, not a parser revert — record any such event in the Decision Log.


## Interfaces and Dependencies

End-state interfaces (full module paths; unchanged items not listed):

```haskell
-- pgmq-core, Pgmq.Types
parseQueueName :: Text -> Either PgmqError QueueName
  -- now rejects: empty, length > 47, any char outside [a-z0-9_]
instance FromJSON QueueName  -- hand-written, validates via parseQueueName
instance ToJSON QueueName    -- unchanged (derived)

-- pgmq-effectful, Pgmq.Effectful.Interpreter (re-exported by Pgmq.Effectful)
isTransient :: PgmqRuntimeError -> Bool
  -- StatementSessionError/ServerStatementError with SQLSTATE 40001, 40P01,
  -- 55P03, 57P01, or class 53 now classifies transient

-- pgmq-hasql, Pgmq.Hasql.Decoders
messageDecoder :: D.Row Message
  -- message column decoded nullable; SQL NULL surfaces as MessageBody Aeson.Null
```

Dependencies: no new library dependencies anywhere. New test suite `pgmq-core-test`
(base, aeson, pgmq-core, tasty, tasty-hunit, text). The hasql error constructors used
in tests (`StatementSessionError`, `ServerStatementError`, `ServerError`,
`UnexpectedRowCountStatementError`) are all exported from `Hasql.Errors` in the pinned
hasql 1.10.3.5. Coordination: plan 129 owns all statement/encoder changes and the
`Maybe Message` break that M3's shibuya fix answers; plan 130 owns the notify SQL and
`notifyChannelName` (whose `toLower` becomes purely defensive once this plan lands);
the master plan's Integration Points assign this plan the consumer bound bumps as the
expected last lander.
