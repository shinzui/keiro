---
type: Improvement Request
title: Bound the versioned cutover budget to its guarded statements
description: >-
  The versioned-cutover lock budget is applied with a transaction-local setting that is never
  restored, so it silently becomes a statement timeout for the rest of the promotion
  transaction. A first attempt to restore it broke a deadline guarantee, so the correct fix
  needs the cutover deadline semantics established first.
timestamp: 2026-09-21T05:10:00Z
requestId: IR-47
status: accepted
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: claude-code-author
    reviewed_at: 2026-09-21T05:10:00Z
    document_timestamp: 2026-09-21T05:10:00Z
    scope: technical-accuracy
    outcome: commented
    provider: anthropic
    model: claude-opus-5
    effort: unspecified
    context: >-
      Author self-review against local Keiro 4c661556. The leak is verified by
      direct probe of the three 0029 functions, not inferred: an unpatched call
      reports ("4998ms", "4998ms") where the caller set ("7s", "3s"). The
      regression that blocks the obvious fix is measured, not estimated, at 5
      failing runs out of 5 with migration 0033 applied against 3 passing runs
      out of 3 without it. The unexplained ~280ms overshoot is recorded as open,
      and the two candidate readings of it are stated rather than resolved. No
      independent reviewer has read this.
---

## What is wrong

`keiro-migrations` migration `0029` applies the versioned-cutover budget with
`set_config('lock_timeout', …, true)` and `set_config('statement_timeout', …, true)` inside
`keiro.keiro_try_projection_cutover_fence_v1`, `keiro.keiro_try_projection_promotion_lock_v1`,
and `keiro.keiro_try_projection_relation_locks_v1`.

The third argument makes the setting transaction-local, not statement-local, and no function
restores it. The budget therefore stays in force for the remainder of the promotion
transaction. In `keiro/src/Keiro/ReadModel/Rebuild/Versioned.hs`, everything after the guarded
relation lock inherits it:

- `verifyGenerationIdentities`
- `promotionObjectsMatch`
- `renamePromotionPair`, which issues the table renames
- `markVersionedRunPromotedStmt` and `finishVersionedPromotionGroupStmt`
- `External.reconcileExternalReadContractsForGroupsTx`

All of that runs under a `statement_timeout` sized for *acquiring a lock*, not for doing the
work. A promotion that has already taken its `ACCESS EXCLUSIVE` locks can be cancelled partway
through and surface an opaque `UnexpectedServerError "57014"` rather than the documented
`VersionedCutoverDeadlineExceeded`. The documented example in
`docs/guides/online-projection-rebuilds.md` uses `cutoverLockTimeoutMs = 5000`, so this is
reachable in ordinary configurations, and larger promotions are likelier to hit it because the
remaining budget shrinks as the attempt proceeds while the post-lock work does not.

## Deterministic reproducer

This needs no contention and no timing margin. In one transaction:

```sql
SET LOCAL statement_timeout = '7s';
SET LOCAL lock_timeout = '3s';
SELECT keiro.keiro_try_projection_relation_locks_v1(
  ARRAY['keiro.keiro_timers'::regclass::oid::bigint],
  clock_timestamp() + interval '5 seconds');
SELECT current_setting('statement_timeout'), current_setting('lock_timeout');
```

Expected `("7s", "3s")`. Actual `("4998ms", "4998ms")`: the caller's settings are clobbered by
the budget and never restored.

## Why the obvious fix is not correct yet

A first attempt added migration `0033`, replacing all three functions so each captured the
prior `lock_timeout` and `statement_timeout`, applied the budget across its guarded statement
only, and restored them on both the success and the timeout path. It was reverted.

With `0033` applied, `VersionedRebuildSpec`'s *"bounds two independently contended target
relations, keeps readers on v1, and resumes promotion"* fails 5 runs out of 5 at
0.779–0.780s. Without it, it passes 3 out of 3. The timings are near-identical across runs, so
this is causation rather than load.

The returned verdict stays correct — `VersionedCutoverDeadlineExceeded` for `"target-relations"`
— and only the elapsed-time bound fails. That bound is not mere test slack. The promotion
deadline is captured **once**, at `Versioned.hs:1225`, and shared by both lock attempts, so with
`cutoverLockTimeoutMs = 500` the whole operation should finish near 500ms. 779ms overshoots the
deadline itself, not just the test's 650ms allowance.

Isolation performed so far:

- Restoring only `statement_timeout` (leaving `lock_timeout` leaked) still fails.
- Removing the restores from the `EXCEPTION` handlers, keeping only the success-path restores,
  still fails.
- The trigger is restoring `statement_timeout` after the **promotion lock** succeeds, before the
  relation-lock attempt — not the relation-lock function's own restore.

Where the additional ~280ms is spent is not explained. That answer is a precondition for a
correct fix, because it decides between two very different readings:

1. The leak was silently shortening cutovers, so the existing `< 0.65` assertion is a record of
   the bug and must change along with the fix.
2. Restoring the setting breaks the deadline guarantee by some other mechanism, in which case
   the restore is wrong as designed.

Note also that a partial fix is not available: if only the relation-lock function restores, it
restores to whatever the promotion-lock function leaked, so the budget still escapes. Any
correct fix has to cover all three functions, which is exactly the combination that regresses
the test.

## What a fix must do

- Explain the ~280ms before changing behaviour. Instrumenting the three functions with
  `clock_timestamp()` at entry, around the guarded statement, and at exit would localize it.
- Keep the single shared deadline authoritative: the whole attempt, not each lock, is what
  `cutoverLockTimeoutMs` bounds. Confirm whether `lock_timeout` applying per lock acquisition is
  why `statement_timeout` is set at all.
- Restore the caller's settings so no work after the guarded statements inherits the budget.
- Keep `0029` untouched and ship a new forward migration, per `keiro-migrations/README.md`.
- Carry the deterministic reproducer above as a regression test; it does not depend on timing.

## Impact

Consumers running online projection rebuilds on 0.18.0.0 and earlier are exposed. There is no
data-loss risk — the promotion transaction aborts and rolls back — but a cutover can fail
opaquely under load, after taking exclusive locks, and the error a consumer sees is not the one
the guide documents.
