---
id: 215
slug: adopt-explicit-checkpoint-lifecycle-semantics-in-the-projection-catalog
title: "Adopt explicit checkpoint lifecycle semantics in the projection catalog"
kind: exec-plan
created_at: 2026-08-09T17:50:24Z
intention: intention_01kzrnkgtcey6a8ar7xqn9tjxx
master_plan: "docs/masterplans/33-make-subscription-checkpoint-lifecycle-explicit-before-the-next-release.md"
---

# Adopt explicit checkpoint lifecycle semantics in the projection catalog

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, every hand-written Keiro subscription declaration records what Kiroku must do
when the exact `(subscription name, consumer-group member)` checkpoint is absent. Startup inventory,
catalog fingerprints, operator previews, and JSON all expose the choice. Keiro refuses a
`FromCurrentHead` subscription when it is supposed to rebuild a cleared replayable target, because
that combination would skip the history needed to restore the target.

Coordinated rebuilds stop updating Kiroku's private `subscriptions` table. They call Kiroku's
public transaction combinator, reset every persisted member of the catalog-declared subscription
names, and abort the complete fence/target/checkpoint transaction when a declared name has no
persisted row. The result is visible in focused PostgreSQL tests and in the projection operations
surface. This plan depends on
`mori://shinzui/kiroku/plans/70-make-subscription-checkpoint-initialization-and-reset-semantics-explicit`
and does not publish either project.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-11T18:44:58Z) Milestone 1: validated published `kiroku-store` 0.5.0.0 and added the
  lifecycle policy to every Keiro catalog, registration, inventory, fingerprint, and operator
  representation.
- [x] (2026-08-11T18:44:58Z) Milestone 2: enforced replay-safe policy combinations at catalog
  validation/startup with precise diagnostics and focused pure tests.
- [x] (2026-08-11T18:44:58Z) Milestone 3: replaced raw checkpoint SQL with Kiroku's reset
  transaction, condemned missing declarations, returned exact reset keys, and proved
  commit/rollback behavior in PostgreSQL.
- [ ] Milestone 4: update examples, operator docs, changelogs, capability evidence, ADRs, and all
  source-cohort validation while leaving release versions and public bounds unchanged.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The current catalog gives a subscription a stable ID, name, source, and claim site, but omits
  initialization intent from its fingerprint and operator inventory. Treating policy as only a
  Kiroku worker option would therefore let operational behavior drift without a catalog change.
- `Keiro.ReadModel.Rebuild.Group` currently executes a private `UPDATE subscriptions ... WHERE
  subscription_name = ANY (...)`. PostgreSQL treats zero matched rows as success, so a cleared
  target could be committed even though no checkpoint was rewound.
- A subscription name is catalog authority, but consumer-group member rows are Kiroku runtime
  state. Keiro can require at least one persisted row per requested name and report exact affected
  keys; it cannot safely create member rows from a configured group size.
- Kiroku EP-70 is complete and `kiroku-store` 0.5.0.0 is now on Hackage under upstream tag
  `kiroku-store-v0.5.0.0`. EP-1 should consume the released API directly; the plan's anticipated
  sibling-source-only integration state no longer applies.
- Kiroku intentionally gives `MissingCheckpointPolicy` `Eq` and `Show` but not `Ord`. Keiro keeps
  the upstream type directly and defines its own exhaustive stable rank and constructor spelling
  for canonical inventory ordering, fingerprints, and operator JSON instead of adding an orphan
  instance or encoding `show` output accidentally.
- The public reset combinator can replace both grouped and unmanaged Keiro rebuild SQL without
  weakening transactionality. The grouped path additionally treats `missingSubscriptionNames` as
  a typed failure and exposes the exact two-member `resetCheckpointKeys`; the 466-example Keiro
  suite proves the failure rolls back targets, fence state, dedup rows, and matched checkpoints.


## Decision Log

Record every decision made while working on the plan.

- Decision: Store Kiroku's closed `MissingCheckpointPolicy` directly on each
  `SubscriptionDeclaration` and project it through registration and inventory.
  Rationale: One shared type prevents translation drift. The policy affects startup behavior and
  must participate in fingerprints, previews, and machine-readable output.
  Date: 2026-08-09

- Decision: Reject `FromCurrentHead` when a subscription owns a replayable target with
  `ClearBeforeReplay`; allow all three explicit policies for preserve/reconcile/live-only targets.
  Rationale: Clearing and then starting at the current head irretrievably skips reconstructible
  history. The other target modes do not make that promise, while `FailIfMissing` remains a safe
  refusal for every mode.
  Date: 2026-08-09

- Decision: Existing checkpoints take precedence over policy and policy changes never rewind them.
  Rationale: The Kiroku prerequisite defines missing-row initialization separately from explicit
  lifecycle mutation. Keiro must preserve that boundary in documentation and tests.
  Date: 2026-08-09

- Decision: Condemn grouped rebuild preparation when any declared reset subscription name is
  absent from Kiroku's reset report.
  Rationale: Continuing after a target clear would create a false successful rebuild. The complete
  transaction must roll back its fence, target preparation, and any checkpoint resets.
  Date: 2026-08-09

- Decision: Validate against sibling Kiroku source without committing a lasting source override or
  changing release bounds.
  Rationale: The feature must integrate before publication, while package versions and bounds are
  intentionally deferred to the later coordinated release.
  Date: 2026-08-09

- Decision: Supersede the sibling-source-only assumption by consuming published `kiroku-store`
  0.5.0.0 and advancing direct bounds to `>=0.5 && <0.6`.
  Rationale: EP-70 was released before EP-1 began. The required public types and transaction
  combinator are now an authoritative Hackage contract, while Keiro's own version and publication
  still belong to the later coordinated release.
  Date: 2026-08-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Keiro's projection catalog is the typed runtime description shared by application startup,
coordinated rebuilds, and operators. `keiro/src/Keiro/Projection/Catalog.hs` defines
`SubscriptionDeclaration`, `InventorySubscription`, `AsyncProjectionRegistration`, validation,
the deterministic catalog fingerprint, and JSON/operator rendering. A subscription declaration
currently contains its catalog ID, Kiroku subscription name, source, and claim site. It does not
state missing-checkpoint behavior.

In this plan, a **missing checkpoint** means no Kiroku row for the exact subscription/member key.
It is not a zero-valued checkpoint.
`mori://shinzui/kiroku/plans/70-make-subscription-checkpoint-initialization-and-reset-semantics-explicit`
introduces `MissingCheckpointPolicy` with `FromBeginning`, `FromCurrentHead`, and `FailIfMissing`;
it also establishes that an existing row always wins. `FromBeginning` materializes zero,
`FromCurrentHead` atomically captures and stores the current event-store head, and `FailIfMissing`
refuses startup before invoking the handler.

`keiro/src/Keiro/ReadModel/Rebuild/Group.hs` prepares coordinated rebuilds. It acquires the fence,
prepares every target, and currently issues Kiroku-schema SQL itself to set matching subscription
rows to position zero. A **condemned transaction** is a Hasql transaction deliberately marked for
rollback after a semantic check fails. The Kiroku prerequisite exposes
`resetSubscriptionCheckpointsTx`, which returns exact affected member keys and requested names for
which no rows existed. Use that result inside the existing preparation transaction.

`keiro/test/CatalogSpec.hs` owns pure catalog validation and fingerprint coverage;
`keiro/test/CatalogOperationsSpec.hs` owns operator representations; and
`keiro/test/GroupRebuildSpec.hs` owns PostgreSQL group preparation, fencing, and rollback tests.
`jitsurei/` contains executable examples and exhaustive declaration sites. Search for record
construction rather than assuming `defaultSubscriptionConfig` reaches every registration.

[ADR 26](../adr/0026-projection-catalog-identities.md) establishes catalog identities and their
shared runtime/operations role. [ADR 28](../adr/0028-library-owned-operator-commands.md) forbids
private dependency-table SQL when the owning library can provide a public operator API.
[ADR 4](../adr/0004-versioned-api-evolution-gates.md) governs the later version/bounds gate; this
plan changes source contracts but does not cross the release gate. The ownership and write-path
evidence principles in `mori://shinzui/mori/okf/adrs/concepts/ADR-20` and
`mori://shinzui/mori/okf/adrs/concepts/ADR-21` reinforce those local decisions. The motivating
request is `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-3`.


## Plan of Work

Milestone 1 establishes one inspectable runtime contract. First confirm the completed exports of
`mori://shinzui/kiroku/plans/70-make-subscription-checkpoint-initialization-and-reset-semantics-explicit`
from sibling source and make them available to Cabal through an untracked local project override.
In `Keiro.Projection.Catalog`, add `checkpointOnMissing :: MissingCheckpointPolicy` to
`SubscriptionDeclaration` and carry it into `AsyncProjectionRegistration` and
`InventorySubscription`. Include the stable constructor spelling in fingerprint input, human
preview, and JSON; do not encode `show` output accidentally. Update all hand-written declarations,
fixtures, golden values, and `jitsurei` examples explicitly. A pure test must prove that changing
only this policy changes the fingerprint while leaving subscription identity unchanged.

Milestone 2 makes unsafe combinations unrepresentable at startup. Extend catalog validation with a
specific error for `FromCurrentHead` on a replayable owner whose target is prepared with
`ClearBeforeReplay`. Report the catalog ID, subscription name, target ID, and the incompatible
policy/mode. `FromBeginning` and `FailIfMissing` remain valid for that target; all explicit policies
remain valid for preserve, reconcile, or live-only ownership. Run the same validator on
hand-written and generated catalogs, before workers start or migrations mutate state. Add a table
test covering every policy/target-mode combination and a startup test proving no handler starts
after an invalid catalog.

Milestone 3 moves rebuild mutation behind Kiroku ownership. Remove the private checkpoint update
from `Keiro.ReadModel.Rebuild.Group`. Pass the non-empty set of catalog-declared subscription names
and reset position zero to `resetSubscriptionCheckpointsTx` inside the same transaction that owns
the rebuild fence and target preparation. If the report contains a missing name, condemn and return
a typed rebuild-preparation error containing sorted missing names; do not construct member rows.
Persist or return the exact reset keys as operation evidence. PostgreSQL tests cover multi-member
reset, an absent declaration, and rollback: after failure, target rows, fence state, and all
checkpoint rows must match their pre-attempt values.

Milestone 4 completes source adoption. Update projection/rebuild guides, public Haddocks,
operations output examples, `CHANGELOG.md`, and capability evidence. Add or amend an ADR for the
durable replay-safety rule and the Kiroku/Keiro ownership boundary. Audit for private table SQL and
for declarations missing the new field. Run the full source cohort against the sibling Kiroku
package, then remove the local override. Do not bump Keiro or Kiroku package versions, edit final
dependency bounds, tag, upload, or mark the Kiroku request completed.


## Concrete Steps

Work from the Keiro repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
```

Before editing, refresh local dependency evidence and confirm the released baseline. Mori supplies
the sibling source location; Hackage and upstream tags remain authoritative for the release state:

```bash
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json
git ls-remote --tags https://github.com/shinzui/kiroku.git 'kiroku-store-v*'
rg -n 'SubscriptionDeclaration|InventorySubscription|AsyncProjectionRegistration|subscriptions' \
  keiro jitsurei docs
```

The released baseline should still be `kiroku-store` 0.4.0.0. After
`mori://shinzui/kiroku/plans/70-make-subscription-checkpoint-initialization-and-reset-semantics-explicit`
is complete, use an untracked `cabal.project.local` entry for
`../kiroku-project/kiroku/kiroku-store` if the normal workspace overlay does not already select it.
Confirm with `git status --short` that the override is not staged and remove it before acceptance.

During milestones 1 and 2, run:

```bash
cabal build keiro jitsurei
cabal test keiro:keiro-test
```

During milestone 3, run the grouped rebuild tests with PostgreSQL available, then repeat the full
Keiro suite:

```bash
cabal test keiro:keiro-test \
  --test-option=--match \
  --test-option='catalog rebuild groups'
cabal test keiro:keiro-test
```

At final source acceptance, run:

```bash
just verify
just check-adr
nix fmt
nix flake check
git diff --check
git status --short
```

Expected output contains no test or format failures, no private Kiroku checkpoint SQL in Keiro,
and no tracked source override, release tag, or version/bounds-only release change.


## Validation and Acceptance

A catalog containing two otherwise identical subscription declarations with different policies
must produce different deterministic fingerprints and distinct operator JSON, while both retain
the same persisted subscription/member identity. Rendering and decoding must use stable values for
all three constructors.

Validation must accept `FromBeginning` and `FailIfMissing` for a `ClearBeforeReplay` replayable
target and reject `FromCurrentHead` before migrations or workers start. The diagnostic names the
subscription and target and explains that seeding the current head would skip the history needed
after clearing. Table tests prove all other declared target-mode combinations.

A PostgreSQL rebuild test creates two member rows for one declared subscription, clears a target,
and prepares the rebuild. It observes both rows at zero and an exact two-key reset report after
commit. A second test includes a declared subscription with no persisted row. The operation returns
the typed missing-name error, and rereading the database proves that target contents, fence state,
and the previously matched checkpoint rows all rolled back. No test or production module outside
Kiroku contains an update against its `subscriptions` table.

The operator preview and JSON expose `checkpointOnMissing` for each subscription. At least one
future-only example uses `FromCurrentHead`, a replayable projection uses `FromBeginning`, and a
strict operational example uses `FailIfMissing`. The complete `cabal test`, `just verify`, ADR, and
flake checks pass against sibling Kiroku source without publishing artifacts.


## Idempotence and Recovery

Catalog and validation edits are ordinary source changes and may be rebuilt repeatedly. Kiroku
initialization is idempotent by contract: once a member row exists, policy resolution returns that
row without moving it. Re-running a coordinated reset to the same position has the same result and
returns the same set of existing keys.

Rebuild preparation is intentionally transactional. On a missing-name report or later statement
failure, condemn the complete transaction and retry only after the operator repairs the missing
worker state or changes the declared group. Never recover by issuing private SQL or synthesizing
consumer-group rows.

If sibling-source compilation is interrupted, remove only the untracked local Cabal override and
re-run the released build. Do not revert unrelated work, move public tags, or publish an
intermediate package. Preserve the plan and request as evidence if implementation is backed out.


## Interfaces and Dependencies

`mori://shinzui/kiroku/plans/70-make-subscription-checkpoint-initialization-and-reset-semantics-explicit`
is the only checkpoint SQL dependency. Consume the real exported names after that plan completes;
do not reproduce a local compatibility type. The required semantic interface is:

```haskell
data MissingCheckpointPolicy
    = FromBeginning
    | FromCurrentHead
    | FailIfMissing

resetSubscriptionCheckpointsTx ::
    NonEmpty SubscriptionName ->
    GlobalPosition ->
    Tx.Transaction SubscriptionCheckpointResetReport
```

`keiro/src/Keiro/Projection/Catalog.hs` must end with equivalent public projections:

```haskell
data SubscriptionDeclaration = SubscriptionDeclaration
    { subscriptionId :: SubscriptionId
    , subscriptionName :: SubscriptionName
    , subscriptionSource :: SubscriptionSource
    , checkpointOnMissing :: MissingCheckpointPolicy
    , subscriptionClaimSite :: ClaimSite
    }

data InventorySubscription = InventorySubscription
    { -- existing identity and source fields
      checkpointOnMissing :: MissingCheckpointPolicy
    }
```

Use a specific `CatalogValidationError` constructor for the replay-unsafe combination and a
specific grouped-rebuild error carrying sorted missing `SubscriptionName` values. The exact record
layout may follow existing Keiro naming conventions, but errors must remain structurally testable;
do not reduce them to strings.

EP-2, [Plan 216](216-generate-and-classify-missing-checkpoint-policy-in-candidate-language-5.md),
generates these declarations and is a hard downstream dependency. Hackage 0.4.0.0 and upstream tag
`kiroku-store-v0.4.0.0` remain the released dependency baseline until the later release workflow
selects versions and bounds.
