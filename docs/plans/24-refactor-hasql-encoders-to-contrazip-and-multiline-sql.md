---
id: 24
slug: refactor-hasql-encoders-to-contrazip-and-multiline-sql
title: "Refactor hasql encoders to contrazip and multiline SQL"
kind: exec-plan
created_at: 2026-05-19T17:13:25Z
---

# Refactor hasql encoders to contrazip and multiline SQL

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This repository talks to PostgreSQL through the `hasql` library. Every SQL statement in
the codebase is paired with a small Haskell value called an *encoder* that explains how
to turn the Haskell argument of the statement into the positional parameters (`$1`,
`$2`, …) of the SQL text. Today many of those encoders are written with hand-rolled
positional tuple projections such as

```haskell
((\(s, _, _) -> s) >$< E.param (E.nonNullable E.text))
  <> ((\(_, d, _) -> d) >$< E.param (E.nonNullable E.text))
  <> ((\(_, _, t) -> t) >$< E.param (E.nonNullable E.timestamptz))
```

This pattern is the canonical anti-example called out in the `hasql` encoder
best-practices guide that lives at
`/Users/shinzui/Keikaku/hub/haskell/hasql-project/docs/hasql-encoders-best-practices.md`.
It scales linearly with arity, the wildcard underscores encode field position by
counting, and silently swapping two same-type arguments produces a runtime semantic
bug that still type-checks.

Separately, several SQL statements in the codebase are still written as multi-line
string literals stitched together with backslash continuations (`"foo \ \bar"`) or with
`Text.unwords` over an explicit list of fragments. GHC 9.12 ships a native
`MultilineStrings` extension that strips common indentation from a `"""..."""`
literal — the readability gain is described in
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/multiline-strings.md`. Several
files in this repository already use the extension; others do not.

After this change a developer who opens any `*.hs` file in this repository that defines
a `Hasql.Statement.Statement` will see:

* Every multi-parameter encoder of 2–7 parameters expressed as `contrazip<N>` over a
  positional tuple — no hand-rolled `(\(_, x, _) -> x) >$< …` projections.
* Every multi-parameter encoder of 8 or more parameters expressed as a named record
  with one `view #fieldName >$<` per field. The threshold and rationale are taken
  directly from the encoder guide §5.
* Every multi-line SQL literal expressed with `"""..."""` (the `MultilineStrings`
  extension) instead of backslash-continued single-line strings or `Text.unwords`.
* Every Cabal stanza that compiles SQL-bearing Haskell carrying `MultilineStrings` in
  its shared `default-extensions` so individual files no longer need their own
  `{-# LANGUAGE MultilineStrings #-}` pragma.

How to see it working: a reader can run the project's two main test suites
(`cabal test keiro-test` and `cabal test keiro-migrations-test`) and see them pass.
A `rg "\\(\\\\\\(" --type haskell` against the repository should return zero hits in
the refactored files — i.e. no remaining tuple-projection lambdas inside encoders.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **Milestone 1: Cabal default-extensions.** Add `MultilineStrings` to the shared
      `common` stanzas of `keiro.cabal`, `jitsurei/jitsurei.cabal`,
      `keiro-migrations/keiro-migrations.cabal`, and `spikes/read-model/spike.cabal`.
      The benchmark cabal `benchmarks/message-db-vs-kiroku/message-db-vs-kiroku.cabal`
      already has it; leave it alone. Confirm `cabal build all` still succeeds.
      *(Done 2026-05-19. `cabal build all` from the repo root succeeds; the
      spike fails to build with a pre-existing keiki-API mismatch in
      `spikes/read-model/src/Spike/Command.hs` — see Surprises.)*
- [x] **Milestone 1 cleanup:** Remove the now-redundant per-file
      `{-# LANGUAGE MultilineStrings #-}` pragmas from every `.hs` that already had
      one (full list in §Plan of Work / Milestone 1). *(Done 2026-05-19.)*
- [ ] **Milestone 2: Refactor `src/Keiro/Inbox/Schema.hs`.**
      - [ ] Replace `markCompletedStmt`'s 3-tuple projection encoder with `contrazip3`.
      - [ ] Replace `markFailedStmt`'s 4-tuple projection encoder with `contrazip4`.
      - [ ] Replace `selectByKeyStmt`'s `fst`/`snd` projection encoder with `contrazip2`.
      - [ ] Convert `selectAllSql` from backslash-continued literal to a `"""..."""`
            multiline literal.
      - [ ] `cabal test keiro-test` passes.
- [ ] **Milestone 3: Refactor `src/Keiro/Outbox/Schema.hs`.**
      - [ ] Replace `claimStmt`'s 2-tuple projection with `contrazip2`.
      - [ ] Replace `markSentStmt`'s 2-tuple projection with `contrazip2`.
      - [ ] Replace `markFailedStmt`'s 5-tuple projection with `contrazip5`.
      - [ ] Convert `selectAllSql`, `rowColumns`, `perKeyPredicate`,
            `perSourcePredicate` to multiline literals.
      - [ ] Convert `claimSql` from `Text.unwords [..]` to a single `"""..."""`
            template with the predicate substituted via a small wrapper helper (the
            predicate text itself stays a `Text` so the policy-driven swap still
            works).
      - [ ] `cabal test keiro-test` passes.
- [ ] **Milestone 4: Refactor `benchmarks/message-db-vs-kiroku/app/Main.hs`.**
      - [ ] `rawKirokuProductionParamsEncoder` is 8 fields over the existing
            `RawKirokuProductionParams` record. Replace the 8 `(\params -> params.field)
            >$< …` lines with `view #field >$< …` per the guide §5 (the record already
            derives `Generic`, so add `OverloadedLabels` to that cabal stanza if it is
            not already there, and depend on `generic-lens`).
      - [ ] `cabal build message-db-vs-kiroku` succeeds.
- [ ] **Milestone 5: Refactor `spikes/read-model/`.**
      - [ ] `Spike/Projection.hs`: replace `advanceLastSeen`'s local `nameTextEnc`
            (a 2-tuple `fst`/`snd` encoder) with `contrazip2`. Replace inline
            single-line SQL literals with multiline literals where the SQL is more
            than ~60 columns wide.
      - [ ] `Spike/ReadModel.hs`: replace the `queryLastSeen.selectStmt` SQL literal
            with a multiline literal (single-parameter, encoder already minimal).
      - [ ] `spikes/read-model/app/Main.hs`: replace `counterAuditHandler.enc`'s
            4-tuple projection encoder with `contrazip4`. Convert the backslash-
            continued SQL literals in `counterView.rmQuery`, `counterAuditView.rmQuery`,
            `createReadModelTables`, `counterViewWrite.upsertStmt`,
            `counterAuditHandler.insertStmt`, and `latestPosition.stmt` to multiline.
      - [ ] `cabal build spike` succeeds (the spike has no test suite — confirm a
            clean build is enough).
- [ ] **Milestone 6: Clean up `test/Main.hs` SQL literal style.** Convert any
      remaining backslash-continued multi-line SQL (search for `\\\\\n` patterns,
      e.g. the `INSERT INTO billing_received_orders` and `INSERT INTO billing_event_log`
      statements at lines 1356 and 1374) to multiline literals. Encoders in this file
      already use `contrazip<N>`; no encoder change is expected. `cabal test
      keiro-test` passes.
- [ ] **Final sweep:** run `rg '\\\(\\\\\\(' --type haskell` from the repository root
      and confirm no hits remain inside the `src/`, `jitsurei/src/`,
      `spikes/read-model/src/`, `spikes/read-model/app/`, `benchmarks/`, and `test/`
      trees. Append a short transcript to the Outcomes section.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Spike (EP-8) does not build on master.** Discovered 2026-05-19, before any
  refactor edits, that `cabal build all` for `spikes/read-model` fails with
  four `GHC-83865` errors in `spikes/read-model/src/Spike/Command.hs:86-87`
  and `:136-137`. The spike pattern-matches against tuples like
  `(_s', _regs', Nothing)` expecting `Maybe co` but `runCommand`/`projection`
  callers in the spike are typed to deliver `[co]`. This is a pre-existing
  keiki-API mismatch unrelated to this refactor. Evidence: ran
  `git stash && cabal build read-model-spike` on commit `80b49fa` — same
  errors. **Decision:** Milestone 5 will still apply the textual refactor
  (encoder + multiline SQL) to `spikes/read-model/`, but the acceptance
  criterion "`cabal build all` succeeds" cannot be met; the surrogate is
  "the touched modules still type-check up to the pre-existing
  `Spike/Command.hs` error" — i.e. no *new* errors are introduced.


## Decision Log

Record every decision made while working on the plan.

- Decision: Apply the encoder guide's "≤7 params → `contrazip<N>` over tuple, ≥8 →
  named record with `view #field`" threshold uniformly. The two existing 22- and
  25-field encoders in `Outbox/Schema.hs` and `Inbox/Schema.hs` already follow the
  record-and-lens pattern, so no extra record needs to be introduced; only the small
  2/3/4/5-tuple statements in those same files need migration to `contrazip`.
  Rationale: matches the guide §5 rule of thumb verbatim; minimises churn on already-
  compliant encoders.
  Date: 2026-05-19

- Decision: Promote `MultilineStrings` to a shared `default-extensions` entry per
  cabal stanza rather than leaving per-file `{-# LANGUAGE MultilineStrings #-}`
  pragmas in place. Rationale: all files that currently opt in are SQL-bearing
  modules and there is no downside to the rest of the package enabling the
  extension (it is a strictly additive syntactic feature — it only affects code
  that uses `"""..."""`). Keeps file headers focused on extensions specific to that
  file.
  Date: 2026-05-19

- Decision: For the `claimSql :: Text -> Text` helper in `Outbox/Schema.hs`, keep
  the policy predicate as a parameter substituted into the SQL via `Text` splicing
  (rather than enumerating four full `"""..."""` queries). Rationale: the predicate
  is a chunk of WHERE-clause text, not a structural change to the statement; the
  rest of the query is identical across all four policies. A single multiline
  template with one substitution point is far more readable than four near-duplicate
  templates.
  Date: 2026-05-19

- Decision: Leave the `Hasql.Decoders` side (`D.Row`) alone for this plan. The
  encoder guide does not prescribe a `Decoders` style, and the existing applicative
  `<$>`/`<*>` row decoders are idiomatic. Rationale: keep this plan tightly scoped
  to the encoder + SQL-string concerns the user flagged.
  Date: 2026-05-19


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The keiro repository is a Haskell event-sourcing framework built on top of three
in-house libraries (`kiroku`, `keiki`, `shibuya`) plus the external `hasql` ecosystem.
SQL statements are constructed in a small number of "schema" modules under
`src/Keiro/*/Schema.hs`, plus the read-model and spike code, plus the test suites.
The repository layout, with the SQL-bearing files marked, is:

```text
keiro/
├── keiro.cabal                                              ← needs MultilineStrings
├── src/Keiro/
│   ├── Inbox/Schema.hs                                      ← refactor in Milestone 2
│   ├── Outbox/Schema.hs                                     ← refactor in Milestone 3
│   ├── ReadModel.hs                                         ← already compliant
│   ├── ReadModel/Schema.hs                                  ← already compliant
│   ├── Snapshot/Schema.hs                                   ← already compliant
│   └── Timer/Schema.hs                                      ← already compliant
├── jitsurei/
│   ├── jitsurei.cabal                                       ← needs MultilineStrings
│   ├── src/Jitsurei/ReadModels.hs                           ← already compliant
│   └── test/Main.hs                                         ← already compliant
├── keiro-migrations/
│   ├── keiro-migrations.cabal                               ← needs MultilineStrings
│   └── test/Main.hs                                         ← already compliant
├── benchmarks/message-db-vs-kiroku/
│   ├── message-db-vs-kiroku.cabal                           ← already has MultilineStrings
│   └── app/Main.hs                                          ← refactor in Milestone 4
├── spikes/read-model/
│   ├── spike.cabal                                          ← needs MultilineStrings
│   ├── src/Spike/Projection.hs                              ← refactor in Milestone 5
│   ├── src/Spike/ReadModel.hs                               ← refactor in Milestone 5
│   └── app/Main.hs                                          ← refactor in Milestone 5
└── test/Main.hs                                             ← polish in Milestone 6
```

Two terms recur in this plan and need definitions up front:

* **encoder**: in the `hasql` library, a value of type `Hasql.Encoders.Params a`
  describes how to turn one Haskell value of type `a` into the positional
  parameters of a SQL statement. For a single-parameter statement it is
  `E.param (E.nonNullable E.text)` (or similar); for multi-parameter statements
  several `Params` fragments are combined with `(<>)` (which is the `Divisible`
  instance under the hood). The recommended way to feed one tuple value through
  several fragments is the `contrazip2 .. contrazip42` family from the
  `contravariant-extras` package: it takes `N` fragments and returns an encoder
  for the `N`-tuple, in left-to-right order. The repository already depends on
  `contravariant-extras ^>= 0.3` in every relevant cabal stanza.

* **`MultilineStrings`**: a GHC 9.12+ language extension. With it on, a
  `"""..."""` literal has its common leading indentation stripped between the
  opening and closing triple quotes, and one leading and one trailing newline
  removed. The full algorithm is documented at
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/multiline-strings.md`
  (steps 1–7 of "Post-Processing Algorithm"). For the SQL strings in this
  repository the practical upshot is: indent the SQL with the same leading
  spaces as the surrounding Haskell, and the runtime string contains the SQL
  without those leading spaces — exactly the shape PostgreSQL expects, and the
  shape that a human reader sees.

Two repository conventions are also relevant:

* The `view #fieldName` syntax used in the existing record encoders comes from
  `generic-lens` + the `OverloadedLabels` extension (already in `default-
  extensions` in `keiro.cabal` and `jitsurei.cabal`). On a record `R` that
  derives `Generic`, `view #foo :: R -> FieldType`.

* Every relevant cabal stanza already lists `contravariant-extras >= 0.3` and
  `generic-lens >= 2.2` (or equivalent) under `build-depends`; no new
  dependencies are introduced by this plan. The benchmark cabal does not
  currently depend on `generic-lens` — Milestone 4 will add it.


## Plan of Work

The work is split into six milestones plus a final sweep. Milestones 1, 4, and 5 are
mechanical refactors confined to one file or one cabal stanza each; milestones 2 and
3 touch the two largest schema modules and are where the bulk of the encoder churn
sits.


### Milestone 1: enable `MultilineStrings` in shared cabal stanzas

Scope: edit four `.cabal` files, then delete now-redundant `{-# LANGUAGE
MultilineStrings #-}` pragmas from the `.hs` files that previously needed them.

What will exist at the end: every package compiles with `MultilineStrings` on by
default; per-file pragmas are gone.

Files to edit:

1. `keiro.cabal` — add `MultilineStrings` to the `common shared` block's
   `default-extensions` list. The block currently reads:

   ```text
   common shared
       default-language:   GHC2024
       default-extensions: DeriveAnyClass
                           DuplicateRecordFields
                           OverloadedLabels
                           OverloadedStrings
                           PackageImports
   ```

   Append `MultilineStrings` so the list reads, in alphabetical-ish order:

   ```text
   common shared
       default-language:   GHC2024
       default-extensions: DeriveAnyClass
                           DuplicateRecordFields
                           MultilineStrings
                           OverloadedLabels
                           OverloadedStrings
                           PackageImports
   ```

2. `jitsurei/jitsurei.cabal` — same edit to its `common shared` block.

3. `keiro-migrations/keiro-migrations.cabal` — add `MultilineStrings` to its
   `common common` `default-extensions` (note the stanza is called `common` not
   `shared` here).

4. `spikes/read-model/spike.cabal` — add `MultilineStrings` to its `common shared`
   `default-extensions`.

Then remove the per-file pragma `{-# LANGUAGE MultilineStrings #-}` from the
following files (every one of them imports from one of the cabal stanzas above):

* `src/Keiro/Inbox/Schema.hs`
* `src/Keiro/Outbox/Schema.hs`
* `src/Keiro/Snapshot/Schema.hs`
* `src/Keiro/Timer/Schema.hs`
* `src/Keiro/ReadModel/Schema.hs`
* `src/Keiro/ReadModel.hs`
* `test/Main.hs`
* `jitsurei/src/Jitsurei/ReadModels.hs`
* `jitsurei/test/Main.hs`
* `keiro-migrations/test/Main.hs`

Do **not** remove the pragma from
`benchmarks/message-db-vs-kiroku/app/Main.hs` — that file's cabal stanza already
lists the extension under `default-extensions`, but the pragma is currently absent;
no change needed there. (Sanity check: if a future reader sees a redundant pragma
warning under `-Wall`, that is fine to clean up; the priority is not introducing
new pragmas.)

Acceptance: `cabal build all` succeeds from the repository root. There is a
caveat — `spikes/read-model` and `benchmarks/message-db-vs-kiroku` live in
their own directories with their own `cabal.project` definitions and may not be
included in the top-level `cabal build all`. Run them explicitly if so:

```bash
(cd /Users/shinzui/Keikaku/bokuno/keiro && cabal build all)
(cd /Users/shinzui/Keikaku/bokuno/keiro/spikes/read-model && cabal build all)
(cd /Users/shinzui/Keikaku/bokuno/keiro/benchmarks/message-db-vs-kiroku && cabal build all)
```


### Milestone 2: refactor `src/Keiro/Inbox/Schema.hs`

Scope: rewrite three small statement encoders and one SQL-string-concatenation
helper. The 25-field `encodedInsertEncoder` is already in the record-and-lens
style; do not touch it.

What will exist at the end: every encoder in this file uses either `E.param`
directly, `contrazip<N>`, or `view #field`-style record lensing — no
`(\(_, x, _) -> x)` tuple projections remain.

Edits, by location:

1. Add `import Contravariant.Extras (contrazip2, contrazip3, contrazip4)` to the
   import block (replacing or augmenting the current
   `import Data.Functor.Contravariant ((>$<))` — the `>$<` import can be removed
   once all uses are gone, which is the case after these edits).

2. `markCompletedStmt`'s current encoder is:

   ```haskell
   ( ((\(s, _, _) -> s) >$< E.param (E.nonNullable E.text))
       <> ((\(_, d, _) -> d) >$< E.param (E.nonNullable E.text))
       <> ((\(_, _, t) -> t) >$< E.param (E.nonNullable E.timestamptz))
   )
   ```

   Replace with:

   ```haskell
   ( contrazip3
       (E.param (E.nonNullable E.text))
       (E.param (E.nonNullable E.text))
       (E.param (E.nonNullable E.timestamptz))
   )
   ```

3. `markFailedStmt`'s current encoder is the 4-tuple version of the same
   pattern. Replace with `contrazip4` over four `E.param (E.nonNullable …)`
   arguments in `Text, Text, Text, UTCTime` order.

4. `selectByKeyStmt`'s current encoder is:

   ```haskell
   ( (fst >$< E.param (E.nonNullable E.text))
       <> (snd >$< E.param (E.nonNullable E.text))
   )
   ```

   Replace with `contrazip2 (E.param (E.nonNullable E.text)) (E.param
   (E.nonNullable E.text))`.

5. `selectAllSql` is currently a backslash-continued single literal:

   ```haskell
   selectAllSql :: Text
   selectAllSql =
     "SELECT source, dedupe_key, message_id, source_event_id, source_global_position, \
     \destination, event_type, schema_version, content_type, schema_registry, \
     ...
     \FROM keiro_inbox"
   ```

   Replace with a `"""..."""` multiline literal:

   ```haskell
   selectAllSql :: Text
   selectAllSql =
     """
     SELECT source, dedupe_key, message_id, source_event_id, source_global_position,
            destination, event_type, schema_version, content_type, schema_registry,
            schema_subject, schema_version_ref, schema_id, schema_fingerprint,
            causation_id, correlation_id, traceparent, tracestate, kafka_topic,
            kafka_partition, kafka_offset, payload_bytes, attributes, occurred_at,
            status, received_at, completed_at, failed_at, last_error
     FROM keiro_inbox
     """
   ```

   Note that `selectByKeyStmt` and `listBySourceStmt` currently append a WHERE/
   ORDER BY suffix using `(<>)`: `selectAllSql <> " WHERE source = $1 AND
   dedupe_key = $2"`. That pattern is fine to keep; the suffix is a single short
   fragment.

Acceptance: `cabal test keiro-test` passes. The `describe "Idempotent integration-
event inbox"` group exercises every refactored statement (`tryInsertProcessingTx`
+ `markCompletedTx` + `markFailedTx` + `lookupInbox` + `listInbox` +
`garbageCollectCompleted`).


### Milestone 3: refactor `src/Keiro/Outbox/Schema.hs`

Scope: rewrite three small statement encoders and four string-concatenation
helpers. The 22-field `encodedRowEncoder` is already record-and-lens; do not
touch it.

Edits, by location:

1. Add `import Contravariant.Extras (contrazip2, contrazip5)` to the import
   block. Remove the `Data.Functor.Contravariant ((>$<))` import once all uses
   are gone.

2. `claimStmt`'s current encoder is:

   ```haskell
   ( ((\(lim, _) -> lim) >$< E.param (E.nonNullable E.int8))
       <> ((\(_, now) -> now) >$< E.param (E.nonNullable E.timestamptz))
   )
   ```

   Replace with `contrazip2 (E.param (E.nonNullable E.int8)) (E.param
   (E.nonNullable E.timestamptz))`.

3. `markSentStmt`'s current encoder is the 2-tuple `(UUID, UTCTime)` version of
   the same pattern. Replace with `contrazip2` over two appropriate `E.param`
   arguments.

4. `markFailedStmt`'s current encoder is a 5-tuple
   `(UUID, Text, Text, UTCTime, UTCTime)`. Replace with `contrazip5` over five
   `E.param` arguments.

5. `selectAllSql` is currently a backslash-continued literal. Replace with a
   `"""..."""` multiline literal preserving the existing column order.

6. `rowColumns` is currently a backslash-continued literal listing `kt.outbox_id,
   kt.message_id, …`. Replace with a `"""..."""` multiline literal.

7. `perKeyPredicate` and `perSourcePredicate` are currently backslash-continued
   SQL predicates. Replace each with a `"""..."""` multiline literal.

8. `claimSql :: Text -> Text` currently assembles its statement with
   `Text.unwords [..., predicate, ...]`. Replace with a single multiline
   template that splices `predicate` in via `(<>)` or a small `Data.Text`
   substitution. Concretely:

   ```haskell
   claimSql :: Text -> Text
   claimSql predicate =
     """
     WITH ready AS (
       SELECT r.outbox_id FROM keiro_outbox r
       WHERE r.status IN ('pending', 'failed')
         AND r.next_attempt_at <= $2
         AND (
     """
       <> predicate
       <> """
     )
       ORDER BY r.created_at
       LIMIT $1
       FOR UPDATE SKIP LOCKED
     )
     UPDATE keiro_outbox kt
     SET status = 'publishing', attempt_count = kt.attempt_count + 1, updated_at = $2
     WHERE kt.outbox_id IN (SELECT outbox_id FROM ready)
     RETURNING
     """
       <> rowColumns
   ```

   (The exact whitespace is illustrative — what matters is that the policy
   predicate slots inside the `AND ( … )` and that `rowColumns` provides the
   trailing column list. Verify by inspecting the generated string in a
   `ghci` session if uncertain; see Validation.)

   The `Text.unwords` import can be removed if no other use remains in the file
   after the edit.

Acceptance: `cabal test keiro-test` passes. The `describe "Durable integration-
event outbox"` group exercises `enqueueOutboxTx`, `claimOutboxBatch` (all four
ordering policies), `markOutboxSent`, and `markOutboxFailedTx`.


### Milestone 4: refactor `benchmarks/message-db-vs-kiroku/app/Main.hs`

Scope: convert the 8-field `rawKirokuProductionParamsEncoder` from positional
record-dot projection lambdas to `view #field` lensing.

Current shape (around line 527):

```haskell
rawKirokuProductionParamsEncoder :: E.Params RawKirokuProductionParams
rawKirokuProductionParamsEncoder =
    ((\params -> params.eventIds) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
        <> ((\params -> params.eventTypes) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        <> ((\params -> params.causationIds) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.uuid))))
        <> ((\params -> params.correlationIds) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.uuid))))
        <> ((\params -> params.payloads) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.jsonb))))
        <> ((\params -> params.metadatas) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.jsonb))))
        <> ((\params -> params.createdAts) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.timestamptz))))
        <> ((\params -> params.streamName) >$< E.param (E.nonNullable E.text))
```

The lambdas here are *not* the positional-tuple anti-pattern (they project named
fields, not positions), but the record has 8 fields, which the guide says puts
us at the named-record-with-lens threshold (§5). Also, three of the four
benchmark-cabal files in this directory list `MultilineStrings` already but not
`OverloadedLabels`, `generic-lens`, or `lens`. The edit:

1. Update the record definition to derive `Generic`:

   ```haskell
   data RawKirokuProductionParams = RawKirokuProductionParams
       { eventIds :: !(Vector UUID)
       , eventTypes :: !(Vector Text)
       , causationIds :: !(Vector (Maybe UUID))
       , correlationIds :: !(Vector (Maybe UUID))
       , payloads :: !(Vector Aeson.Value)
       , metadatas :: !(Vector (Maybe Aeson.Value))
       , createdAts :: !(Vector UTCTime)
       , streamName :: !Text
       }
       deriving stock (Generic)
   ```

2. Replace the encoder with the lens-per-field form:

   ```haskell
   rawKirokuProductionParamsEncoder :: E.Params RawKirokuProductionParams
   rawKirokuProductionParamsEncoder =
       (view #eventIds       >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
           <> (view #eventTypes     >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
           <> (view #causationIds   >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.uuid))))
           <> (view #correlationIds >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.uuid))))
           <> (view #payloads       >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.jsonb))))
           <> (view #metadatas      >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.jsonb))))
           <> (view #createdAts     >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.timestamptz))))
           <> (view #streamName     >$< E.param (E.nonNullable E.text))
   ```

3. Update `benchmarks/message-db-vs-kiroku/message-db-vs-kiroku.cabal`:

   * Add `OverloadedLabels` and `DeriveGeneric` to `default-extensions`.
   * Add `generic-lens ^>= 2.2` and `lens ^>= 5.2` (and `Data.Generics.Labels`
     comes with `generic-lens`) to `build-depends`.
   * Add the corresponding `import Control.Lens (view)` and
     `import Data.Generics.Labels ()` lines to `app/Main.hs`.

4. Convert any remaining backslash-continued SQL literals in this file to
   multiline literals (the file already has `MultilineStrings` enabled at the
   cabal level — quick wins; do not get drawn into rewriting the benchmark's
   big WITH-CTE strings unless they are already wrapped in `"""..."""` — they
   are, so this is a noop in practice).

Acceptance: `cabal build` from `benchmarks/message-db-vs-kiroku/` succeeds. No
test suite for the benchmark; this is a build-only acceptance.


### Milestone 5: refactor `spikes/read-model/`

Scope: three files; mechanical encoder + SQL-literal cleanup.

`spikes/read-model/src/Spike/Projection.hs`:

* Add `import Contravariant.Extras (contrazip2)`. Remove the
  `Data.Functor.Contravariant ((>$<))` import once unused.
* `advanceLastSeen` defines a local `nameTextEnc :: Encoders.Params (Text, Int64)`
  that uses `fst >$< …` and `snd >$<`. Replace its body with
  `contrazip2 (Encoders.param (Encoders.nonNullable Encoders.text)) (Encoders.param
  (Encoders.nonNullable Encoders.int8))`.
* Inline single-line SQL literals (`upsertStmt`, `stmt` in `readLastSeen`, `stmt`
  in `advanceLastSeen`) are short enough to stay as one-liners; leave them.

`spikes/read-model/src/Spike/ReadModel.hs`:

* `queryLastSeen.selectStmt` has a one-line SQL literal; leave as-is.
* No encoder changes needed.

`spikes/read-model/app/Main.hs`:

* `counterAuditHandler.enc` is a 4-tuple projection encoder. Replace with
  `contrazip4` over four `Encoders.param (Encoders.nonNullable …)` arguments.
  Add `import Contravariant.Extras (contrazip4)`.
* Backslash-continued SQL literals in `counterView.rmQuery`,
  `counterAuditView.rmQuery`, `createReadModelTables` (two `execSql` calls),
  `counterViewWrite.upsertStmt`, `counterAuditHandler.insertStmt`,
  `latestPosition.stmt`: convert each to a `"""..."""` multiline literal. The
  cabal-level extension was added in Milestone 1.

Acceptance: `cabal build all` from `spikes/read-model/` succeeds.


### Milestone 6: polish `test/Main.hs`

Scope: this file already uses `contrazip<N>` in every refactored encoder. The
remaining nit is two backslash-continued SQL literals
(`insertReceivedOrderStmt`'s SQL and `appendBillingEventLogStmt`'s SQL are
single-line; the only `\..\`-style continuation in the file at the moment is
the `insertReceivedOrderStmt` body around line 1356–1357: `"INSERT INTO
billing_received_orders … \ \ON CONFLICT (order_id) DO NOTHING"`). Convert
those to multiline literals.

Acceptance: `cabal test keiro-test` passes.


### Final sweep

Run

```bash
rg "\\\(\\\\\\(" --type haskell src/ jitsurei/ keiro-migrations/ benchmarks/ spikes/ test/
```

(`\(\\\\(` in shell-escaped form, but `\(\(` in actual regex — i.e. a literal
`((` immediately followed by a Haskell lambda backslash) and verify the output
is empty. Then append the transcript to the Outcomes & Retrospective section.


## Concrete Steps

All commands assume the working directory `/Users/shinzui/Keikaku/bokuno/keiro` unless
noted otherwise.

1. Confirm the toolchain on this machine. Expected GHC 9.12.x (the cabal files set
   `tested-with: GHC == 9.12.*`):

   ```bash
   ghc --version
   cabal --version
   ```

   Expected output (versions may vary slightly):

   ```text
   The Glorious Glasgow Haskell Compilation System, version 9.12.3
   cabal-install version 3.12.x.x
   ```

2. Snapshot the current state of failing-or-passing tests so regressions are easy
   to spot:

   ```bash
   cabal build all
   ```

   The build should succeed against the master branch (commit `80b49fa`,
   "revert: roll back EP-23 (Shibuya inbox adapter)").

3. Execute milestones 1–6 in order, committing after each milestone. Commit
   message format (Conventional Commits + ExecPlan trailer):

   ```text
   refactor(hasql): enable MultilineStrings in shared cabal stanzas

   Adds MultilineStrings to keiro.cabal, jitsurei.cabal,
   keiro-migrations.cabal, and spike.cabal common stanzas and drops the
   now-redundant per-file pragmas across src/, jitsurei/src/,
   keiro-migrations/, and test/.

   ExecPlan: docs/plans/24-refactor-hasql-encoders-to-contrazip-and-multiline-sql.md
   ```

   Use one commit per milestone; pre-commit hooks are not bypassed.

4. After each milestone, run the relevant test suite:

   ```bash
   cabal test keiro-test
   cabal test keiro-migrations-test
   (cd jitsurei && cabal test)
   ```

5. After Milestone 5, verify the spike still builds:

   ```bash
   (cd spikes/read-model && cabal build all)
   ```

6. After Milestone 4, verify the benchmark still builds:

   ```bash
   (cd benchmarks/message-db-vs-kiroku && cabal build all)
   ```


## Validation and Acceptance

Behavioural acceptance is straightforward: every existing test that exercises a
`hasql` Statement must continue to pass. There is no observable runtime behaviour
change in this refactor; the encoders produce the same parameter bytes and the SQL
strings produce the same logical query.

Specific check commands:

* **Inbox transitions** (Milestone 2). After Milestone 2:

  ```bash
  cabal test keiro-test --test-options="--match \"Idempotent integration-event inbox\""
  ```

  Expected output (Hspec-style summary, last line):

  ```text
  Finished in N.NNNN seconds
  N examples, 0 failures
  ```

* **Outbox transitions** (Milestone 3). After Milestone 3:

  ```bash
  cabal test keiro-test --test-options="--match \"Durable integration-event outbox\""
  ```

  Same shape of output, 0 failures.

* **Benchmark build** (Milestone 4):

  ```bash
  (cd benchmarks/message-db-vs-kiroku && cabal build all)
  ```

  Expected: a fresh `dist-newstyle` build product appears, exit code 0.

* **Spike build** (Milestone 5):

  ```bash
  (cd spikes/read-model && cabal build all)
  ```

  Expected: exit code 0.

* **Full test sweep** (after every milestone is done):

  ```bash
  cabal test all
  (cd jitsurei && cabal test all)
  (cd keiro-migrations && cabal test all)
  ```

  Each call must report 0 failures.

* **Encoder anti-pattern sweep** (final acceptance — proves the refactor is
  effective beyond compilation):

  ```bash
  rg "\\\(\\\\\\(" --type haskell src/ jitsurei/ keiro-migrations/ benchmarks/ spikes/ test/
  ```

  Expected output: empty. Any remaining hits indicate a tuple-projection lambda
  inside an encoder fragment, which is exactly the anti-pattern we are removing.

  Additionally:

  ```bash
  rg "fst >\\\$<|snd >\\\$<" --type haskell src/ jitsurei/ keiro-migrations/ benchmarks/ spikes/ test/
  ```

  Expected output: empty. (`fst`/`snd` projections are the 2-tuple version of the
  same anti-pattern.)

* **Multiline-string sweep**: list every `"""..."""` literal touched:

  ```bash
  rg '"""' --type haskell src/ jitsurei/ keiro-migrations/ benchmarks/ spikes/ test/
  ```

  Expected: many hits — at minimum every CREATE TABLE / SELECT / INSERT in the
  refactored files. Eyeball-check that there are no `\<text>\\` continuations
  remaining in SQL strings.


## Idempotence and Recovery

The refactor is purely textual — no schema migrations, no data changes, no on-disk
state. Every step can be retried by re-running it; every milestone can be
re-implemented by reverting the corresponding commit and starting over (`git
revert <commit>` or, if not yet pushed, `git reset --hard HEAD~1`). Because no
behaviour changes, even a partially applied refactor leaves the system runnable
— individual files compile independently, and the tests don't care whether one
encoder uses `contrazip2` and another still uses tuple projections.

If `cabal test keiro-test` starts failing mid-refactor with a hasql parameter-
ordering error (e.g. `column "source" is of type text but expression is of type
timestamp with time zone`), the most likely cause is that a `contrazip<N>`
argument order does not match the SQL's `$N` order. The fix is to re-read the
SQL's positional parameters and reorder the `contrazip` arguments. As a sanity
check: in a `contrazip3 a b c` call, `a` encodes the first tuple element, which
SQL refers to as `$1`. Always match left-to-right.


## Interfaces and Dependencies

No new library dependencies are added by Milestones 1–3, 5, 6 (every relevant
cabal stanza already lists `contravariant-extras`, `generic-lens`, and `lens`).
Milestone 4 adds `generic-lens` and `lens` to
`benchmarks/message-db-vs-kiroku/message-db-vs-kiroku.cabal` and adds the
`OverloadedLabels` / `DeriveGeneric` extensions to the same cabal stanza.

Function signatures that change publicly: none. Every refactored function
preserves its existing type (the input tuple or record stays the same; only the
internal encoder definition changes). For example:

* `markCompletedStmt :: Statement (Text, Text, UTCTime) ()` stays the same.
* `claimStmt :: OrderingPolicy -> Statement (Int64, UTCTime) [OutboxRow]` stays
  the same.
* `rawKirokuProductionParamsEncoder :: E.Params RawKirokuProductionParams`
  stays the same.

Modules touched, by full path:

* `keiro.cabal`
* `jitsurei/jitsurei.cabal`
* `keiro-migrations/keiro-migrations.cabal`
* `spikes/read-model/spike.cabal`
* `benchmarks/message-db-vs-kiroku/message-db-vs-kiroku.cabal`
* `src/Keiro/Inbox/Schema.hs`
* `src/Keiro/Outbox/Schema.hs`
* `src/Keiro/Snapshot/Schema.hs` (pragma removal only)
* `src/Keiro/Timer/Schema.hs` (pragma removal only)
* `src/Keiro/ReadModel/Schema.hs` (pragma removal only)
* `src/Keiro/ReadModel.hs` (pragma removal only)
* `test/Main.hs`
* `jitsurei/src/Jitsurei/ReadModels.hs` (pragma removal only)
* `jitsurei/test/Main.hs` (pragma removal only)
* `keiro-migrations/test/Main.hs` (pragma removal only)
* `benchmarks/message-db-vs-kiroku/app/Main.hs`
* `spikes/read-model/src/Spike/Projection.hs`
* `spikes/read-model/src/Spike/ReadModel.hs`
* `spikes/read-model/app/Main.hs`

Libraries the refactor relies on, with the role each plays:

* `hasql` — the `Hasql.Encoders` (`E.Params`, `E.param`, `E.nonNullable`,
  `E.nullable`, `E.text`, …) and `Hasql.Statement` (`Statement`, `preparable`)
  APIs. Already in scope everywhere.
* `contravariant-extras` — provides `contrazip2 .. contrazip42`. Already a
  build-depends of every relevant stanza.
* `generic-lens` and `lens` — provide `view` and the `OverloadedLabels`
  `#fieldName` resolution. Already used in the existing record encoders in
  `Inbox/Schema.hs` and `Outbox/Schema.hs`; Milestone 4 adds them to the
  benchmark cabal.
* `Data.Generics.Labels ()` (re-exported by `generic-lens`) — the orphan
  instance bridge that makes `#fieldName` resolve to a lens. Imported wherever
  `view #x` is used.

Reference docs to consult while implementing — these are file paths, not URLs:

* `/Users/shinzui/Keikaku/hub/haskell/hasql-project/docs/hasql-encoders-best-practices.md`
  — the full encoder-style guide. §3 covers `contrazip<N>`; §5 covers the
  ≥8-parameter named-record rule; §7 covers the encoder-on-record alternative.
* `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/multiline-strings.md` —
  the full `MultilineStrings` post-processing-algorithm doc. The
  "Post-Processing Algorithm" section enumerates the seven steps GHC applies.
