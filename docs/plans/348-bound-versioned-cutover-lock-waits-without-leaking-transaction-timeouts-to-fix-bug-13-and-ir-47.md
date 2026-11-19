---
id: 348
slug: bound-versioned-cutover-lock-waits-without-leaking-transaction-timeouts-to-fix-bug-13-and-ir-47
title: "Bound versioned cutover lock waits without leaking transaction timeouts to fix BUG-13 and IR-47"
kind: exec-plan
created_at: 2026-11-19T02:49:04Z
intention: "intention_01m7rvaa08ehqsksvr9jrbr3j0"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-19T02:49:04Z
---

# Bound versioned cutover lock waits without leaking transaction timeouts to fix BUG-13 and IR-47

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro can rebuild a read model into new tables while the old ones keep serving, and then
swap them in one short transaction called the promotion. The swap needs exclusive locks.
An operator gives each attempt a budget, `cutoverLockTimeoutMs`: if the locks cannot be
taken within it, the attempt must roll back and report the typed outcome
`VersionedCutoverDeadlineExceeded`, so the run can be resumed later.

Three SQL helper functions enforce that budget. They do it by setting PostgreSQL's
`lock_timeout` and `statement_timeout` for the rest of the transaction and never putting
them back. Two things go wrong as a result. First, every later statement in the
promotion transaction, including the table renames that run after the locks are won, is
cancelled if it takes longer than whatever was left of the lock budget, and the caller
sees the untyped error `UnexpectedServerError "57014"` (PostgreSQL's code for a cancelled
statement) in place of the typed outcome. This is bug report
[BUG-13](../bug-reports/13-versioned-cutover-deadline-surfaces-as-statement-timeout.md),
seen as an intermittent test failure under load. Second, any timeouts the calling
application had set itself are overwritten. This is improvement request
[IR-47](../improvement-requests/bound-the-versioned-cutover-budget-to-its-guarded-statements.md).

After this change the helpers bound only their own lock waits, restore the caller's
`lock_timeout`, and never touch `statement_timeout`. A lock that cannot be taken in time
always yields `VersionedCutoverDeadlineExceeded`. Work done after the locks are won is no
longer cancelled by a leftover lock budget. You can see it working by running the
migration tests and the versioned rebuild tests: new examples that fail today show the
caller's settings surviving each helper and a slow statement after a helper completing,
and the existing example that holds two tables against a 500 ms budget still finishes
within 650 ms.


## Progress

- [ ] Milestone 1: new examples in `keiro-migrations/test/Main.hs` fail against the
  current helpers, showing the clobbered settings, the cancelled later statement and the
  overshoot of the relation helper on its own. BUG-13 moves to `in-progress`.
- [ ] Milestone 2: migration `0034` replaces the three helpers. The Milestone 1 examples
  pass, the migration inventory accepts 34 Keiro migrations, and the versioned rebuild
  examples pass, including the two-relation budget example.
- [ ] Milestone 3: ADR-34, the user guide, the rebuild guide and the changelogs describe
  the new enforcement. BUG-13 is `fixed`, IR-47 is linked to this plan and closed, and
  `nix develop -c just verify` passes.


## Surprises & Discoveries

- Observation: the helpers' own `statement_timeout` never bounds their own statement.
  PostgreSQL arms the statement timer when a top-level statement starts. Changing the
  setting inside a function called by that statement does not re-arm it. The setting only
  takes effect for later statements in the transaction.
  Evidence: Case 6 below, where the relation helper sets a 500 ms `statement_timeout`
  and still runs for 795 ms.

- Observation: this explains the 280 ms overshoot that IR-47 left open. `lock_timeout`
  restarts for every lock wait, so one `LOCK TABLE a, b` statement can wait up to the
  budget on each table. Today the promotion attempt is held to its deadline only because
  the promotion-lock helper leaks a `statement_timeout`, which is armed when the
  relation-lock statement starts and cancels it near the deadline. IR-47's first fix
  restored the setting, removed that accidental bound, and the two-relation test went
  from about 500 ms to 779 ms.
  Evidence, from `docs/bug-reports/evidence/BUG-13-leaked-cutover-timeouts.txt`
  (PostgreSQL 18.6, 500 ms budget, first table released about 280 ms in, second held):

    ```text
    == Case 6: relation helper alone
     elapsed_ms_for_500ms_budget
                             795
    == Case 7: same contention, preceded by the promotion-lock helper
     elapsed_ms_for_500ms_budget
                             501
    ```

- Observation: a 57014 can escape the handlers in two ways today. A statement between
  the helpers, or after them, can exceed the leaked timeout. And the relation-lock
  statement itself runs under a timer that expires later than its lock wait by the time
  spent between the two helpers; if the statement is still running at that moment, after
  its handler has already returned, it is cancelled. Both were reproduced (Cases 2, 3 and
  5 in the evidence file). The statement that failed in the original gate run was not
  captured, so which of the two occurred there is not known.

- Observation: a prototype of the replacement relation helper (in Plan of Work) meets
  the budget without any statement timeout.
  Evidence, same contention as Case 6, caller settings `7s` and `3s`:

    ```text
     elapsed_ms | statement_timeout | lock_timeout | exclusive_locks_held
            501 | 7s                | 3s           |                    0
    ```


## Decision Log

- Decision: Enforce the budget with `lock_timeout` alone, recomputed from the absolute
  deadline immediately before every individual lock wait. Lock the target relations one
  at a time, in the order given, inside one exception block.
  Rationale: `lock_timeout` is the only setting that takes effect inside the running
  statement, and it applies per wait. Recomputing it before each wait makes the sum of
  the waits respect the deadline. `LOCK TABLE a, b` already acquires its locks one at a
  time in list order, so the acquisition order and the deadlock behaviour do not change.
  One exception block means a timeout rolls back every lock the helper took, as the
  single statement does today.
  Date: 2026-11-19

- Decision: The helpers stop setting `statement_timeout` and stop catching
  `query_canceled`.
  Rationale: The setting has no effect on the helper's own statement and is the source
  of both defects. Once the helpers no longer set it, a cancellation inside a helper can
  only be the caller's own `statement_timeout` or an operator's cancel request. Neither
  is a cutover deadline, and reporting them as one would hide them.
  Date: 2026-11-19

- Decision: Ship the change as a new forward migration that replaces the three functions
  with `CREATE OR REPLACE FUNCTION`, keeping the names, signatures and return values.
  Rationale: `keiro-migrations/README.md` forbids editing a shipped migration. The
  contract the Haskell callers depend on (names, arguments, the result strings and
  boolean) does not change, so no `_v2` name is needed, the SQL text in
  `Keiro.ReadModel.Rebuild.Versioned` stays as it is, and binaries already released get
  the fix as soon as the migration is applied. `CREATE OR REPLACE` keeps the existing
  `REVOKE … FROM PUBLIC`.
  Date: 2026-11-19

- Decision: The budget bounds lock waits only. Work done after the locks are won is no
  longer cancelled when the budget runs out.
  Rationale: This is what the documentation already says (`cutoverLockTimeoutMs` is "an
  absolute database-clock budget for one writer-fence or promotion attempt" applied to
  the group-row lock and the relation locks). The cancellation of post-lock work was an
  undocumented side effect that produced an untyped error after exclusive locks were
  held. A caller that wants a ceiling on the whole transaction can set its own
  `statement_timeout`, which the helpers now leave alone. This removes an accidental
  bound and must be stated in the changelog.
  Date: 2026-11-19

- Decision: Leave the promotion-group helper's single `SELECT … FOR UPDATE OF runs,
  groups` as one statement.
  Rationale: It can wait on two row locks, so in the worst case it can overshoot the
  budget by one further budget. It is the first helper in its transaction, so no leaked
  timer bounds it today either, and this plan does not make it worse. Splitting it would
  change the order in which the run and group rows are locked relative to other code
  paths and needs its own analysis. Record it as a follow-up improvement request when
  this plan closes.
  Date: 2026-11-19


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root. Run every command from the repository
root, because entering the Nix development shell from a package directory creates a stray
PostgreSQL cluster there.

**The helpers.** `keiro-migrations/migrations/0029.sql` (lines 72 to 218) defines three
PL/pgSQL functions in the `keiro` schema.
`keiro_try_projection_cutover_fence_v1(requested_run_id, requested_contract, attempt_deadline)`
updates the rebuild group row to stop writers and returns `'fenced'`, `'not-ready'` or
`'deadline-exceeded'`.
`keiro_try_projection_promotion_lock_v1(requested_run_id, requested_contract, attempt_deadline)`
locks the run and group rows and returns `'locked'`, `'not-ready'` or
`'deadline-exceeded'`.
`keiro_try_projection_relation_locks_v1(relation_oids, attempt_deadline)` resolves the
table names for a list of relation identifiers and takes `ACCESS EXCLUSIVE` locks on all
of them with one `LOCK TABLE` statement, returning `TRUE` or `FALSE`. Each computes the
milliseconds left before `attempt_deadline`, calls
`set_config('lock_timeout', …, true)` and `set_config('statement_timeout', …, true)`,
and runs its guarded statement inside a block that catches `lock_not_available` and
`query_canceled`. The third argument `true` makes a setting last until the transaction
ends. Nothing restores it.

**The callers.** `keiro/src/Keiro/ReadModel/Rebuild/Versioned.hs` holds the Haskell side.
`enterVersionedCutoverTx` (near line 1046) captures a deadline with
`capturePromotionDeadlineStmt` (`clock_timestamp() + budget`) and calls the fence helper.
`promoteVersionedRebuildTx` (near line 1218) captures one deadline, calls the
promotion-lock helper, reads the run, the group and the serving and candidate
generations, calls the relation-lock helper through `lockPromotionRelations`, and then,
holding the exclusive locks, verifies identities, renames the tables with
`renamePromotionPair`, marks the run and group promoted and reconciles external-read
objects. A helper result of `'deadline-exceeded'` or `FALSE` becomes
`VersionedCutoverDeadlineExceeded runId phase`, where the phase is `"writer-fence"`,
`"promotion-group"` or `"target-relations"`; `condemned` marks the transaction for
rollback. The helper SQL text is in three statements near line 2996.

**The tests.** `keiro/test/VersionedRebuildSpec.hs` belongs to the `keiro-test` suite.
The example "bounds two independently contended target relations, keeps readers on v1,
and resumes promotion" (line 808) holds one table for 0.3 s and another for 1 s against a
500 ms budget and requires the typed `"target-relations"` outcome in under 0.65 s. This
is the example that IR-47's earlier fix broke, and it is the gate for the budget
guarantee here. The example "rolls every cutover boundary back to one v1 authority and
resumes the same incompatible v2 promotion" (line 1065) uses a 100 ms budget and is the
one that failed intermittently in BUG-13.

`keiro-migrations/test/Main.hs` is the migration suite. It checks that the manifest, the
embedded migrations and the checksum file agree, and it contains per-migration examples
such as "0033 preserves legacy timer/workflow rows with nullable advisory trace fields"
(line 680), which apply migrations to a fresh database with `withKeiroPg` and run SQL
through `Session.script`. Three places encode the migration count or list: the
expectations `shouldBe 33` near lines 86 and 215, the identifier list ending in
`("keiro", "0033")` near line 1353, and the file list ending in `"0033.sql"` near
line 1399.

**Migration bookkeeping.** `keiro-migrations/migrations/manifest` lists the migration
files in order. `keiro-migrations/migrations.native.lock` holds one line per file, a
SHA-256 checksum followed by two spaces and the file name, as printed by `shasum -a 256`
without the directory. A new migration is created with the `keiro-migrate new` command
shown in Concrete Steps. The schema snapshot at
`keiro-migrations/expected-schema/native/keiro-v18.txt` does not record these functions,
so it should not change; the migration suite will say so if it does.

**Decisions already recorded.**
[ADR-34](../adr/0034-online-projection-rebuilds-use-schema-versioned-target-generations.md)
describes the promotion: each attempt captures a new absolute deadline, and Keiro
"acquires them with one cumulative `ACCESS EXCLUSIVE` `LOCK TABLE` statement whose
timeout is the remaining deadline". That sentence describes the mechanism this plan
replaces and must be updated. The same wording appears in
`docs/user/read-models-and-projections.md` (near line 437, "one cumulative lock
statement") and `docs/guides/online-projection-rebuilds.md` (near line 116, "one
deterministically ordered statement").
[ADR-9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md) defines the
checksum file and the rule that shipped migrations are immutable. No other ADR is
relevant.

**Validation already done.** On 2026-11-19 the three helpers were loaded verbatim into a
scratch database on PostgreSQL 18.6 and exercised with `psql`. The script and transcript
are in `docs/bug-reports/evidence/BUG-13-leaked-cutover-timeouts.txt`. The findings are
summarised in Surprises & Discoveries. The original failure under full-gate load was not
re-run.


## Plan of Work

### Milestone 1: failing examples for the helper contract

Add a group of examples to `keiro-migrations/test/Main.hs`, beside the "0033 …" example,
that apply the full migration plan to a fresh database and call the helpers directly.
They need a second connection to hold a lock; open it with the same `withConnection`
helper and run the holder on another thread, as `keiro/test/VersionedRebuildSpec.hs`
does with `forkIO` and an `MVar`.

The first example proves the caller's settings survive. In one transaction it runs
`SET LOCAL statement_timeout = '7s'` and `SET LOCAL lock_timeout = '3s'`, calls one
helper, and reads `current_setting('statement_timeout')` and
`current_setting('lock_timeout')`. It does this for all three helpers on their
uncontended paths (the fence and promotion helpers may be called with a run identifier
that does not exist; they return `'not-ready'` after running the guarded statement) and
for the relation helper on its timeout path, with another connection holding
`ACCESS SHARE` on the table. The expected result is `("7s", "3s")` every time. Today it
is the remaining budget, for example `("4998ms", "4998ms")`.

The second example proves later work is not cancelled. In one transaction it calls the
relation helper on an unlocked table with a deadline 100 ms away and then runs
`SELECT pg_sleep(0.3)`. The expected result is success. Today the sleep fails with
SQLSTATE 57014.

The third example proves the relation helper keeps the budget by itself. Two other
connections hold `ACCESS SHARE` on two tables, the first for about 0.3 s and the second
for 1 s. The example calls only the relation helper, with both tables in that order and
a deadline 500 ms away, and expects `FALSE`, an elapsed time under 650 ms, and no
`AccessExclusiveLock` held by its own session in `pg_locks` afterwards. Today it takes
about 800 ms.

Run the suite and confirm all three fail for the stated reasons. Then set BUG-13's
`status` to `in-progress`, update `docs/bug-reports/index.md` and add a line to
`docs/bug-reports/log.md`.

### Milestone 2: migration 0034

Create the migration with `keiro-migrate new` (see Concrete Steps). It must begin with a
one-line SQL comment describing it, as `0033.sql` does, and contain three
`CREATE OR REPLACE FUNCTION` statements with the same names, argument lists, return
types, `LANGUAGE plpgsql`, `SECURITY INVOKER` and
`SET search_path = pg_catalog, pg_temp` clauses as in `0029.sql`. Do not edit `0029.sql`.

The relation helper becomes the prototype below, which was run against the contention of
the third example and returned `FALSE` in 501 ms with the caller's settings intact and no
lock retained.

```sql
CREATE OR REPLACE FUNCTION keiro.keiro_try_projection_relation_locks_v1(
  relation_oids BIGINT[],
  attempt_deadline TIMESTAMPTZ
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  prior_lock_timeout TEXT := current_setting('lock_timeout');
  remaining_ms BIGINT;
  relation_names TEXT[];
  relation_name TEXT;
BEGIN
  SELECT array_agg(format('%I.%I', namespaces.nspname, relations.relname) ORDER BY requested.ordinality)
  INTO relation_names
  FROM unnest(relation_oids) WITH ORDINALITY AS requested(relation_oid, ordinality)
  JOIN pg_class AS relations ON relations.oid = requested.relation_oid
  JOIN pg_namespace AS namespaces ON namespaces.oid = relations.relnamespace;

  IF relation_names IS NULL
     OR cardinality(relation_names) IS DISTINCT FROM cardinality(relation_oids) THEN
    RAISE EXCEPTION 'one or more promotion relations no longer exist';
  END IF;

  BEGIN
    FOREACH relation_name IN ARRAY relation_names LOOP
      -- lock_timeout restarts for every wait, so recompute it from the absolute
      -- deadline before each relation. The sum of the waits then respects the budget.
      remaining_ms := ceil(extract(epoch FROM (attempt_deadline - clock_timestamp())) * 1000);
      IF remaining_ms <= 0 THEN
        RAISE lock_not_available;
      END IF;
      PERFORM set_config('lock_timeout', remaining_ms::text || 'ms', true);
      EXECUTE 'LOCK TABLE ' || relation_name || ' IN ACCESS EXCLUSIVE MODE';
    END LOOP;
  EXCEPTION
    WHEN lock_not_available THEN
      PERFORM set_config('lock_timeout', prior_lock_timeout, true);
      RETURN FALSE;
  END;
  PERFORM set_config('lock_timeout', prior_lock_timeout, true);
  RETURN TRUE;
END;
$$;
```

The error message for a missing relation and the behaviour for an empty or unresolvable
list must stay as they are in `0029.sql`; compare the two bodies before finishing.

The fence and promotion-lock helpers keep their guarded statements unchanged. Each
records `current_setting('lock_timeout')` on entry, returns `'deadline-exceeded'` when
no time is left, sets only `lock_timeout` to the remaining time, runs the guarded
statement inside a block that catches only `lock_not_available`, and restores the
recorded `lock_timeout` on every return path. Neither calls `set_config` for
`statement_timeout`.

Then update the bookkeeping. Append the checksum line for the new file to
`keiro-migrations/migrations.native.lock`. In `keiro-migrations/test/Main.hs`, change
the two `shouldBe 33` expectations to 34, append `("keiro", "0034")` to the identifier
list and `"0034.sql"` to the file list, and check whether the `take 32` in the "0033 …"
example or any similar prefix needs no change (it should not; it selects the migrations
before `0033`). If the new file has a descriptive suffix, use its real name and
identifier in these lists.

No Haskell source in `keiro/src` needs to change. Update the comment above the helpers'
statements in `keiro/src/Keiro/ReadModel/Rebuild/Versioned.hs` only if it describes the
old mechanism.

### Milestone 3: documentation and closure

Update ADR-34's promotion paragraph: the relations are locked one at a time in
deterministic order, each wait is limited to the time left before the attempt's
deadline, the helpers restore the caller's `lock_timeout` and do not set
`statement_timeout`, and the budget covers lock waits, not the work done under the
locks. Advance the ADR's `timestamp` and add a log entry with `okf log add` (see
`okf log add --help`). Make the matching wording change in
`docs/user/read-models-and-projections.md` and
`docs/guides/online-projection-rebuilds.md`, and add one sentence telling operators that
a ceiling on the whole promotion transaction is their own `statement_timeout`.

Add entries under `## [Unreleased]` in `keiro-migrations/CHANGELOG.md` (migration `0034`)
and in `CHANGELOG.md` (bug fix for `keiro-migrations` and `keiro`: typed deadline
outcome, restored settings, and the removal of the accidental cancellation of post-lock
work).

Set BUG-13 to `fixed` with `fixedVersion: "unreleased"` and a `resolution` sentence, and
update the bug-report index and log. In IR-47's file
(`docs/improvement-requests/bound-the-versioned-cutover-budget-to-its-guarded-statements.md`)
add `plan: docs/plans/348-bound-versioned-cutover-lock-waits-without-leaking-transaction-timeouts-to-fix-bug-13-and-ir-47.md`
to the frontmatter, rewrite its "Status" section to say what shipped and that the
overshoot is explained, and set the status the improvement-request profile uses for
implemented requests (read `mori/improvement-requests-profile.dhall` and a completed
request such as
`docs/improvement-requests/add-an-explicit-terminal-outbox-rejection-outcome.md`). File a
new improvement request for the two-row-lock overshoot of the promotion-group helper
described in the Decision Log.


## Concrete Steps

Check the shell first, from the repository root:

```bash
nix develop -c z3 --version
```

Run the migration suite; after Milestone 1 the three new examples fail, after Milestone 2
everything passes:

```bash
nix develop -c cabal test keiro-migrations:keiro-migrations-test --test-show-details=direct
```

Create the migration and check the manifest:

```bash
nix develop -c cabal run keiro-migrate -- new \
  --manifest keiro-migrations/migrations/manifest \
  --description "bound cutover lock waits without leaking timeouts"
nix develop -c cabal run keiro-migrate -- check keiro-migrations/migrations/manifest
```

Compute the checksum line for the lock file (replace the name if the tool chose a
different one):

```bash
(cd keiro-migrations/migrations && shasum -a 256 0034.sql)
```

Run the versioned rebuild examples, then the whole suite:

```bash
nix develop -c cabal test keiro:test:keiro-test --test-show-details=direct \
  --test-options='--match "/schema-versioned/"'
nix develop -c cabal test keiro:test:keiro-test --test-show-details=direct
```

If the `--match` pattern selects nothing, list the group names with
`grep -n 'describe "' keiro/test/VersionedRebuildSpec.hs` and match on those.

Run the two-relation example five times in a row; IR-47's reverted fix failed it five
times out of five, so five passes is the required evidence:

```bash
for i in 1 2 3 4 5; do
  nix develop -c cabal test keiro:test:keiro-test --test-show-details=direct \
    --test-options='--match "bounds two independently contended target relations"' || break
done
```

Finally run the repository gate:

```bash
nix develop -c just verify
```


## Validation and Acceptance

The change is accepted when all of the following hold, and the closing notes name the
evidence for each.

The three Milestone 1 examples fail before migration `0034` and pass after it: the
caller's `statement_timeout` and `lock_timeout` are unchanged after every helper on both
its success and timeout paths; a 300 ms statement after a helper with a 100 ms deadline
completes; and the relation helper alone returns `FALSE` within 650 ms against two
contended tables and retains no exclusive lock.

The budget guarantee is not weakened. The example "bounds two independently contended
target relations, keeps readers on v1, and resumes promotion" passes five consecutive
runs with its `< 0.65` bound untouched. Do not relax that bound.

The typed outcomes are not weakened. The fault-injection example "rolls every cutover
boundary back to one v1 authority and resumes the same incompatible v2 promotion" and
the rest of `VersionedRebuildSpec` pass unchanged, so `"writer-fence"`,
`"promotion-group"` and `"target-relations"` deadlines still roll back to one V1
authority and a later resume still promotes.

A relation-lock timeout still leaves no partial state: `FALSE` is returned with every
lock from that call released, and no rename or metadata change commits. The third
Milestone 1 example checks the locks; the existing examples check the rest.

The lock acquisition order is unchanged: the relations are locked in the array order
that `lockPromotionRelations` builds by sorting on the physical table name.

Two behaviours change on purpose and must appear in the changelog. Work after the locks
are won is no longer cancelled when the lock budget runs out. A cancellation that
arrives inside a helper (the caller's own `statement_timeout`, or an operator's cancel)
is no longer reported as a cutover deadline; it surfaces as the database error it is.

There is no performance path to regress. The promotion makes the same number of round
trips; the relation helper runs one `LOCK TABLE` per relation inside a single function
call where it ran one for all. The `keiro-bench` release-gate guards do not measure
cutover, so the timing evidence is the 650 ms bound in the two examples above, not a
benchmark.

As supporting evidence, not required for acceptance, repeat the original failure
conditions: run the fault-injection example in a loop while another terminal runs
`nix develop -c cabal build all --enable-tests --enable-benchmarks`, and confirm that no
run reports SQLSTATE 57014. If one does, the failing statement is in `db/postgres.log`;
record it in Surprises & Discoveries before changing anything.


## Idempotence and Recovery

The tests create and drop their own databases and can be re-run freely. `keiro-migrate
new` appends to the manifest; if it is run twice by mistake, delete the extra file and
its manifest line before committing. Until the migration has been released, its SQL may
be edited, and the checksum line must then be recomputed. Once released it is immutable
and any correction is another forward migration.

Applying migration `0034` is safe on a live database: `CREATE OR REPLACE FUNCTION` swaps
each body atomically and does not touch stored data. A promotion already in flight keeps
the function body it started with for the statement it is running. To roll back in an
emergency, re-create the three functions from `0029.sql` in a further forward migration.

Binaries released before this change call the same function names and get the new
behaviour once the migration is applied. Binaries built after it refuse to start against
a database without the migration, through the existing pending-migration handshake.


## Interfaces and Dependencies

The SQL functions `keiro.keiro_try_projection_cutover_fence_v1(TEXT, TEXT, TIMESTAMPTZ)
RETURNS TEXT`, `keiro.keiro_try_projection_promotion_lock_v1(TEXT, TEXT, TIMESTAMPTZ)
RETURNS TEXT` and `keiro.keiro_try_projection_relation_locks_v1(BIGINT[], TIMESTAMPTZ)
RETURNS BOOLEAN` keep their signatures, result values and privileges. Their contract
gains two clauses: on return, `lock_timeout` has the value it had on entry, and
`statement_timeout` is never written.

`Keiro.ReadModel.Rebuild.Versioned` keeps its exported types and functions, including
`VersionedCutoverDeadlineExceeded` and the `cutoverLockTimeoutMs` request field. No
dependency is added or upgraded. `keiro-migrations` gains one migration, so consumers
must apply it with their usual `keiro-migrate up` step when they upgrade.

Commits made under this plan carry both trailers:

```text
ExecPlan: docs/plans/348-bound-versioned-cutover-lock-waits-without-leaking-transaction-timeouts-to-fix-bug-13-and-ir-47.md
Intention: intention_01m7rvaa08ehqsksvr9jrbr3j0
```
