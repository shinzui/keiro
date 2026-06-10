---
id: 66
slug: add-safe-stream-construction-helpers-category-api-to-keiro-stream
title: "Add safe stream-construction helpers (Category API) to Keiro.Stream"
kind: exec-plan
created_at: 2026-06-10T13:39:04Z
intention: "intention_01ktrvackbe7jrenk79j8jgb5e"
---

# Add safe stream-construction helpers (Category API) to Keiro.Stream

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, every Keiro application builds the physical name of an aggregate's event stream by
hand-concatenating a category prefix with an entity id, e.g.:

```haskell
incidentStream :: IncidentId -> Stream IncidentEventStream
incidentStream incidentId = stream ("incident-" <> idText incidentId)
```

This pattern is repeated in every aggregate module, and it leaks an invariant that the
**store**, not the user, owns: in Kiroku a stream name's *category* is "the substring before
the first `-`" (see `kiroku-store/src/Kiroku/Store/Types.hs:27-30,262-268`). Category-scoped
reads (`Kiroku.Store.Read.readCategory`) and category subscriptions fan in every stream whose
name shares that prefix. So the literal `"incident-"` is not a cosmetic string — it is the
join key that decides which streams a projection or subscription sees. Hand-writing it per
call site has three concrete hazards:

1. **No single source of truth.** The same literal is duplicated across `incidentStream`,
   `incidentCommandStream`, projections, and subscription wiring. A typo in one place silently
   creates an orphan category.
2. **Silent category mis-parsing.** A "category" that itself contains a `-` — e.g. the saga
   prefix `"hospital-surge-"` (`keiro-dsl/src/Keiro/Dsl/Grammar.hs:397-405`) or a workflow
   name with a hyphen — parses as the category `hospital`, *not* `hospital-surge`. The
   process-manager stream then fans into the `hospital` aggregate's category by accident.
3. **No typed bridge to category reads.** There is no way to recover the `CategoryName` for a
   `readCategory`/subscription from the same definition that built the per-entity stream;
   users re-type the bare string a second time.

After this change, an author declares the category **once** as a validated, phantom-typed
value and derives both per-entity streams and the category name from it:

```haskell
incidentCategory :: StreamCategory IncidentEventStream
incidentCategory = categoryUnsafe "incident"          -- validated at definition site

incidentStream :: IncidentId -> Stream IncidentEventStream
incidentStream = entityStreamId incidentCategory      -- renders "incident-<id>"

-- and, for projections / subscriptions, the matching CategoryName for free:
-- categoryName incidentCategory == CategoryName "incident"
```

> Note: the type is named `StreamCategory` (not `Category`) to avoid clashing with the
> established `Kiroku.Store.Subscription.Types.Category` subscription-target constructor — see
> the Decision Log and Surprises.

**Observable outcome:** in `keiro-core`, `Keiro.Stream` exports a `Category` type with smart
constructors that *reject* a category containing the reserved `-` boundary (so hazard #2
becomes a compile-time-recommended/`error`-at-startup failure instead of a silent fan-in bug),
an `entityStream`/`entityStreamId` builder, and a `categoryName` accessor. A new unit-test
group proves that `categoryName cat` always equals Kiroku's own category-of-stream-name rule
for any stream `entityStream cat id` produces. The in-repo example (`keiro/jitsurei`) and the
DSL/saga prefix handling are updated to flow through the new API, demonstrating the boilerplate
and the footgun both disappear.

**Relationship to kiroku-store (split design).** The "category = substring before first `-`"
rule is *owned by kiroku*, not keiro: it is enforced by the `streams.category GENERATED ALWAYS
AS split_part(stream_name,'-',1)` column and re-derived in
`Kiroku.Store.Notification.categoryFromPayload`. So the **mechanical, permissive** half of this
work — a public `categoryName :: StreamName -> CategoryName` accessor and a
`streamNameInCategory :: CategoryName -> Text -> StreamName` constructor — lands in kiroku-store
under its own ExecPlan, **#55**
(`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/docs/plans/55-expose-canonical-category-accessor-and-safe-stream-name-constructor-in-kiroku-store.md`,
same intention). This plan (#66) builds the **opinionated, phantom-typed** layer on top:
`Category a` tagging by aggregate, the rejecting validation, and `entityStream`/`entityStreamId`,
all *delegating* the actual name mechanics to kiroku so the rule has exactly one definition in
code. **#66 Milestone 1 depends on #55 Milestone 1 having landed** and on `keiro-core`'s
`kiroku-store` lower bound being bumped to the version that exports the new API.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M0 — kiroku-store #55 landed.** (2026-06-10) #55 pushed to `origin/master` on
  `shinzui/kiroku` (`ffcf3a1`). keiro's `cabal.project` git pin for both `kiroku-store` and
  `kiroku-store-migrations` advanced from `97408c2` (0.1.0.0) to `ffcf3a1` (0.2.0.0), and
  `keiro-core`'s `kiroku-store` lower bound bumped to `>=0.2`. The temporary local-path override
  has been removed. `cabal build keiro-core` resolves and builds against the git-pinned
  `kiroku-store-0.2.0.0`, and the **full `keiro-test` suite passes** (the 64-commit kiroku jump
  did not break any keiro DB-backed test). Note: the codd "DB and expected schemas do not match"
  log line during fixture setup is **benign** — `templateCoddSettings` uses `LaxCheck` with an
  empty on-disk rep (`keiro-test-support/src/Keiro/Test/Postgres.hs:147-158`), so it logs every
  schema object as unexpected by design and never fails; no expected-schema regen was required
  (see Surprises, corrected).
- [x] **M1 — Category API in `keiro-core`.** (2026-06-10) Added `StreamCategory` (renamed from
  `Category`, see Decision Log), `CategoryError`, `category`, `categoryUnsafe`, `categoryName`,
  `StreamIdSegment` (+ `Text`/`String` instances), `entityStream` (delegating to
  `Store.streamNameInCategory`), `entityStreamId` to `Keiro.Stream`; re-exports `CategoryName`.
  `cabal build keiro-core` clean against the local kiroku `0.2.0.0`.
- [x] **M2 — Unit tests.** (2026-06-10) Extended the `Keiro.Stream` group in
  `keiro/test/Main.hs`: validation cases (empty / `-` / `$all` / `:` sub-namespace), the
  `entityStream` round-trip asserted against kiroku's own `Store.categoryName`, and the
  `entityStreamId` `Text`/`String` paths. `cabal test keiro-test --match "Keiro.Stream"` →
  `4 examples, 0 failures`, suite PASS. (The full DB-backed suite is blocked by an unrelated
  codd schema-mismatch from the kiroku version jump — see Surprises.)
- [ ] **M3 — Adopt in the in-repo example + reconcile compound categories.** Migrate
  `keiro/jitsurei` stream construction to the Category API; document/validate the `wf:` and
  saga (`hospital-surge-`) compound-category conventions. In-repo build + tests pass.
- [ ] **M4 (cross-repo, optional) — Migrate `keiro-runtime-jitsurei` services.** Replace
  per-aggregate hand-concat with module-level `Category` values and `StreamIdSegment`
  instances; rebuild that repo against the new `keiro-core`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Compound prefixes silently collapse to a shorter category.** The saga grammar stores a raw
  prefix string `"hospital-surge-"` (`keiro-dsl/src/Keiro/Dsl/Grammar.hs:397-405`) and the
  in-repo process managers build names like `stream ("hospital-surge-" <> idText hospitalId)`.
  By Kiroku's rule (category = text before first `-`,
  `kiroku-store/src/Kiroku/Store/Types.hs:262-268`) these streams have category `hospital`,
  i.e. the *same* category as the `hospital` aggregate (`stream ("hospital-" <> ...)`). A
  `readCategory (CategoryName "hospital")` therefore fans the surge-manager streams in with the
  hospital aggregate streams. Whether intended or not, today nothing makes this visible. The
  workflow helper avoids it by using `:` as an intra-family separator: `wf:<name>-<id>`
  (`keiro/src/Keiro/Workflow/Types.hs:101-103`) keeps the category as `wf:<name>`. The Category
  API will standardize on that convention (use `:` to sub-namespace; reject `-` in a category).

- **2026-06-10 — `Category` name collides with the subscription target.** Exporting a
  `Category` type from `Keiro.Stream` (re-exported wholesale by the `Keiro` umbrella) produced
  an *ambiguous occurrence* against `Kiroku.Store.Subscription.Types.Category` (the `Category
  !CategoryName` subscription target) — which the keiro test, and real subscription-writing
  consumer code, import unqualified alongside `Keiro`. Renamed the new type to `StreamCategory`
  (see Decision Log). Evidence: `keiro/test/Main.hs:3084,3105` use `Category (CategoryName …)`
  as a subscription target; GHC `[GHC-87543]` ambiguity until the rename.
- **2026-06-10 — the codd "schema mismatch" log is benign (corrected).** Initially read as a
  blocker from the ~64-commit kiroku jump, the `withMigratedSuite` fixture's "DB and expected
  schemas do not match" line is actually expected: `templateCoddSettings`
  (`keiro-test-support/src/Keiro/Test/Postgres.hs:147-158`) runs codd with `LaxCheck` and an
  **empty** on-disk rep (`DbRep Null Map.empty Map.empty`), so codd logs every kiroku schema
  object as "not-expected-but-found" on every run, by design, and never fails. The full
  `keiro-test` suite passes against `kiroku-store-0.2.0.0`. No expected-schema regeneration was
  needed. (The `.dev/codd-expected-schema` directory is used by tooling outside the test suite,
  not by `withMigratedSuite`.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Place the new API in `Keiro.Stream` (package `keiro-core`), not a new module.
  Rationale: `Keiro.Stream` already owns the `Stream`/`StreamName` boundary (`stream`,
  `streamName`, `mapStreamName`) and already imports `Kiroku.Store.Types`. Co-locating keeps
  one home for stream identity and avoids a new exposed-module + dependency edge.
  Date: 2026-06-10

- Decision: A `Category` carries the same phantom type `a` as the `Stream a` it produces.
  Rationale: call sites are typed today as `IncidentId -> Stream IncidentEventStream`; a
  `Category IncidentEventStream` lets `entityStream`/`entityStreamId` return the correctly
  tagged handle and prevents mixing categories across aggregates.
  Date: 2026-06-10

- Decision: Reject `-` in a category at construction (`category` returns `Either CategoryError`;
  `categoryUnsafe` calls `error`). Use `:` for intra-family sub-namespacing.
  Rationale: `-` is Kiroku's category/id boundary; allowing it in a category reintroduces the
  silent fan-in footgun (see Surprises). `:` is already the established convention (`wf:`,
  `pm:fulfillment`) and is accepted by the store.
  Date: 2026-06-10

- Decision: Keep `entityStream :: Category a -> Text -> Stream a` as the primitive and add a
  `StreamIdSegment` class with an `entityStreamId :: StreamIdSegment i => Category a -> i ->
  Stream a` ergonomic layer (instances for `Text`, `String`; domain id types add a one-line
  instance, typically `renderIdSegment = Text.pack . show`).
  Rationale: matches the existing per-module `idText = Text.pack . show` exactly while removing
  the duplicated category literal; does not force an instance on users who already hold `Text`.
  Date: 2026-06-10

- Decision: Do not re-export `CategoryName` from `Keiro.Stream`.
  Rationale: `CategoryName`'s canonical home is `Kiroku.Store.Types`, and consumers doing
  category reads/subscriptions already import it there. Re-exporting it through `Keiro.Stream`
  (and thus the `Keiro` umbrella) made those consumers' explicit `Kiroku.Store.Types
  (CategoryName(..))` imports redundant (a `-Wunused-imports` warning, observed at
  `keiro/test/Main.hs:213`). `categoryName` still returns a `CategoryName`; callers name the type
  via kiroku as before. Date: 2026-06-10

- Decision: Name the typed category `StreamCategory a`, not `Category a`.
  Rationale: `Keiro.Stream` is re-exported wholesale by the `Keiro` umbrella, so an unqualified
  `Category` collides with the established `Kiroku.Store.Subscription.Types.Category`
  subscription-target constructor that subscription-writing code imports alongside `Keiro`
  (confirmed by a GHC ambiguity in the test suite). `StreamCategory` is also more precise — it
  is literally the category of a `Stream`. Smart constructors (`category`, `categoryUnsafe`),
  the accessor (`categoryName`), and `entityStream`/`entityStreamId` keep their names (no clash).
  Date: 2026-06-10

- Decision: Split the work with kiroku-store (ExecPlan #55). kiroku-store gets the mechanical,
  permissive `categoryName :: StreamName -> CategoryName` accessor and `streamNameInCategory ::
  CategoryName -> Text -> StreamName` constructor; keiro-core's `entityStream` *delegates* to
  `streamNameInCategory` and keiro's round-trip test asserts against kiroku's `categoryName`
  rather than reimplementing `takeWhile (/= '-')`.
  Rationale: the "category = before first `-`" rule is enforced by kiroku's schema (generated
  column) and already re-derived in `Notification.categoryFromPayload`; reimplementing it a
  third time in keiro is exactly the drift kiroku's own sync-comment warns against. kiroku owns
  the rule, so the constructor/accessor live there (and benefit other consumers like
  shibuya-kiroku-adapter); keiro owns aggregate-tagging and the opinionated rejection.
  Date: 2026-06-10

- Decision: Scope the *mandatory* work to the `keiro` repo (API + tests + in-repo example +
  DSL/saga reconciliation). Treat migrating the separate `keiro-runtime-jitsurei` repo as an
  optional follow-up milestone (M4), since it is a downstream consumer in its own git repo.
  Rationale: the new API must land and be proven in `keiro-core` first; consumers adopt after.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This work lives in the **`keiro`** repository at `/Users/shinzui/Keikaku/bokuno/keiro` (a Nix +
Cabal Haskell project, GHC ≥ 9.12, `default-language: GHC2024`). It is a separate repository
from `kiroku` (the event store) and from `keiro-runtime-jitsurei` (an application that consumes
keiro). The ExecPlan file itself lives at
`docs/plans/66-add-safe-stream-construction-helpers-category-api-to-keiro-stream.md` inside the
keiro repo.

Terms used below, defined plainly:

- **Stream** — an append-only log of events for a single aggregate instance, identified by a
  textual **stream name** (e.g. `"incident-inc_01h…"`). Defined in the Kiroku event store:
  `StreamName` is `newtype StreamName = StreamName Text`
  (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Types.hs:40`).
- **Category** — by Kiroku's own definition, "the substring before the first `-`" in a stream
  name. `StreamName "orders-1"` has `CategoryName "orders"`
  (`kiroku-store/src/Kiroku/Store/Types.hs:27-30, 262-268`). Used by
  `Kiroku.Store.Read.readCategory` and by category-target subscriptions to fan many per-entity
  streams into one ordered read. `CategoryName` is `newtype CategoryName = CategoryName Text`.
  Names *without* a dash, names containing commas, and `$`-prefixed names are all accepted by
  the store; only the exact name `$all` is reserved.
- **`Stream a`** — keiro's phantom-typed wrapper around a `StreamName`, in
  `keiro-core/src/Keiro/Stream.hs`:
  ```haskell
  newtype Stream a = Stream { name :: StreamName }
  stream        :: Text -> Stream a                                   -- raw, unchecked
  streamName    :: Stream a -> StreamName
  mapStreamName :: (StreamName -> StreamName) -> Stream a -> Stream a
  ```
  The phantom `a` is normally the aggregate's `EventStream …` type alias (e.g.
  `Stream IncidentEventStream`) or its command type (`Stream IncidentCommand`).
- **`EventStream`** — the full runnable description of a stream
  (`keiro-core/src/Keiro/EventStream.hs:48-56`). Its field
  `resolveStreamName :: Stream (EventStream …) -> StreamName` maps the typed handle to the
  physical name; in practice it is **always** set to `Stream.streamName` (the identity),
  confirmed across every generated and hand-written aggregate (e.g.
  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs:1017`, all
  `keiro-dsl/test/conformance-*/Generated/**/EventStream.hs:24`). The per-entity `Stream`
  handle is supplied by the *caller* and consumed by the command runtime
  (`keiro/src/Keiro/Command.hs:240,290` apply `resolveStreamName` to the caller's
  `targetStream`).

How streams are built **today** (the boilerplate this plan removes), with citations:

- Per-aggregate, in `keiro-runtime-jitsurei`, two near-identical functions per aggregate:
  ```haskell
  -- services/incident-command/src/IncidentCommand/Incident/EventStream.hs:40-44
  incidentStream :: IncidentId -> Stream IncidentEventStream
  incidentStream incidentId = stream ("incident-" <> idText incidentId)
  incidentCommandStream :: IncidentId -> Stream IncidentCommand
  incidentCommandStream incidentId = stream ("incident-" <> idText incidentId)
  -- with, near the bottom of the module:
  idText :: Show a => a -> Text
  idText = Text.pack . show         -- line 233-234; redefined in every aggregate module
  ```
  The same shape appears for `hospital`, `capacity`, `reservation`, `resource`, `triage`, and
  for process managers with **compound** prefixes: `stream ("hospital-surge-" <> idText …)`
  (SurgeManager) and `stream ("incident-escalation-" <> idText …)` (Escalation).
- Workflow streams have a dedicated helper already:
  ```haskell
  -- keiro/src/Keiro/Workflow/Types.hs:101-103
  workflowStreamName :: WorkflowName -> WorkflowId -> StreamName
  workflowStreamName (WorkflowName name) (WorkflowId wid) =
      StreamName ("wf:" <> name <> "-" <> wid)
  ```
  This is the model to generalize: a fixed family prefix (`wf:<name>`) joined to an id by `-`.
- In-repo example `keiro/jitsurei/app/Main.hs` hand-builds names too:
  `let chapterStreamName = "chapter-" <> memberIdText member <> "-" <> chapterIdText chapter`
  (line 382) and `workflowStreamNameText` unwrapping `workflowStreamName` (lines 472-474).
- The DSL captures a saga's stream prefix as **raw text**:
  `SagaRef { sagaStreamPrefix :: Text }` from `saga Surge stream="hospital-surge-" <>
  correlationId` (`keiro-dsl/src/Keiro/Dsl/Grammar.hs:397-405`). The DSL scaffold itself does
  **not** emit per-entity `*Stream` functions — it only emits the `EventStream` record with
  `resolveStreamName = Stream.streamName` (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs:991-1021`).
- The process-manager runtime takes the per-entity handle as a caller-supplied lambda:
  `streamFor :: Text -> Stream (EventStream …)` (`keiro/src/Keiro/ProcessManager.hs:82,95,213`).

Build/test entry points:

- `keiro-core` library exposed modules include `Keiro.Stream`
  (`keiro-core/keiro-core.cabal`, `exposed-modules`). It has **no** test-suite of its own.
- The repo's test-suite is `keiro-test`, `main-is: Main.hs`, `hs-source-dirs: test`, in
  `keiro/keiro.cabal:125-129`; that suite already depends on `keiro-core`, so new unit tests
  for the Category API go there (avoids adding a new test-suite + dependency closure to
  `keiro-core`).


## Plan of Work

All file paths below are relative to the keiro repo root
`/Users/shinzui/Keikaku/bokuno/keiro`. Commands are run from that root inside the project's
dev environment (e.g. `nix develop`, the same environment used for plans 46–65).

### Milestone 1 — Category API in `keiro-core`

Scope: add the new types and functions to `keiro-core/src/Keiro/Stream.hs` and widen its
export list. No behavior change to existing functions. At the end, `keiro-core` builds and the
new symbols are importable.

Edit `keiro-core/src/Keiro/Stream.hs`:

1. Extend the import of Kiroku types to bring in `CategoryName` and the new #55 functions.
   Import the functions **qualified** to avoid clashing with keiro's own `categoryName ::
   Category a -> CategoryName`:
   ```haskell
   import Kiroku.Store.Types (CategoryName (..), StreamName (..))
   import Kiroku.Store.Types qualified as Store   -- Store.categoryName, Store.streamNameInCategory (ExecPlan #55)
   ```
   and import `Data.Text qualified as Text` (via `Keiro.Prelude` if it already re-exports it;
   otherwise add the import — check `keiro-core/src/Keiro/Prelude.hs` first). This requires the
   `kiroku-store` lower bound in `keiro-core/keiro-core.cabal` to be bumped to the version that
   ships #55's API; update that bound in this milestone.

2. Extend the module export list to add the new surface:
   ```haskell
   module Keiro.Stream (
       Stream (..),
       stream,
       streamName,
       mapStreamName,
       -- new: safe, category-based construction
       Category (..),
       CategoryError (..),
       CategoryName (..),     -- re-export for category reads/subscriptions
       category,
       categoryUnsafe,
       categoryName,
       StreamIdSegment (..),
       entityStream,
       entityStreamId,
   )
   ```

3. Add the new definitions (place after the existing `mapStreamName`):
   ```haskell
   -- | A validated stream /category/: the prefix that precedes the first
   -- @-@ in every stream name belonging to this family. Kiroku defines a
   -- stream's category as the substring before its first @-@, so a category
   -- must itself contain no @-@. Carries the same phantom type @a@ as the
   -- 'Stream' handles it produces. Use @:@ to sub-namespace within a family
   -- (e.g. @"hospital:surge"@), matching the @wf:<name>@ workflow convention.
   newtype Category a = Category { categoryTextOf :: Text }
       deriving stock (Generic, Eq, Ord, Show)

   -- | Why a 'Text' is not a valid 'Category'.
   data CategoryError
       = CategoryEmpty
       | CategoryContainsSeparator !Text  -- ^ contains the reserved @-@ boundary
       | CategoryReserved !Text           -- ^ equals a store-reserved name (@$all@)
       deriving stock (Eq, Show, Generic)

   -- | Validate a 'Text' as a 'Category'. Rejects the empty string, any text
   -- containing @-@ (Kiroku's category/id boundary), and the reserved name
   -- @$all@.
   category :: Text -> Either CategoryError (Category a)
   category t
       | Text.null t            = Left CategoryEmpty
       | t == "$all"            = Left (CategoryReserved t)
       | Text.isInfixOf "-" t   = Left (CategoryContainsSeparator t)
       | otherwise              = Right (Category t)

   -- | Partial constructor for static, known-good category literals at
   -- definition sites. Calls 'error' on an invalid category; never pass user
   -- input. Intended for top-level @fooCategory = categoryUnsafe "foo"@.
   categoryUnsafe :: Text -> Category a
   categoryUnsafe t = either (error . show) id (category t)

   -- | The 'CategoryName' for category-scoped reads
   -- ('Kiroku.Store.Read.readCategory') and category subscription targets.
   categoryName :: Category a -> CategoryName
   categoryName (Category t) = CategoryName t

   -- | Render a value as the /id segment/ of a stream name (the part after
   -- the first @-@). The id may itself contain @-@ without corrupting the
   -- leading category, but must be non-empty to keep the stream name distinct
   -- from a bare category read.
   class StreamIdSegment i where
       renderIdSegment :: i -> Text

   instance StreamIdSegment Text where
       renderIdSegment = id

   instance StreamIdSegment String where
       renderIdSegment = Text.pack

   -- | Build the per-entity 'Stream' handle for an aggregate instance,
   -- rendering @<category>-<id>@. The phantom type is carried from the
   -- 'Category', so the result is correctly tagged. The actual name
   -- mechanics are delegated to kiroku's 'Store.streamNameInCategory'
   -- (ExecPlan #55), keeping the category rule single-sourced in the store.
   entityStream :: Category a -> Text -> Stream a
   entityStream (Category c) idSeg =
       Stream{name = Store.streamNameInCategory (CategoryName c) idSeg}

   -- | 'entityStream' for a typed id with a 'StreamIdSegment' instance.
   -- Domain id types typically add @instance StreamIdSegment FooId where
   -- renderIdSegment = Text.pack . show@.
   entityStreamId :: StreamIdSegment i => Category a -> i -> Stream a
   entityStreamId c = entityStream c . renderIdSegment
   ```

   Note: `Category`'s field accessor is named `categoryTextOf` to avoid colliding with the
   `categoryName` function and with `DuplicateRecordFields`/`OverloadedLabels` in scope. If a
   simpler `#category` label is preferred, adjust — confirm against `Keiro.Prelude`'s lens
   re-exports before finalizing the field name.

Acceptance: `cabal build keiro-core` compiles with `-Wall` clean (the package enables
`-Wall -Wcompat …`; ensure no redundant-import / partial-field warnings — `Category` is a
single-field record so `-Wpartial-fields` is fine).

### Milestone 2 — Unit tests

Scope: prove the validation rules and, crucially, that `categoryName cat` always equals
Kiroku's own "category before first `-`" rule for any name `entityStream cat id` produces. Add
a self-contained test group to the existing `keiro-test` suite (`keiro/test/Main.hs`), since it
already links `keiro-core`.

Add a `Keiro.Stream` describe/group with at least these cases (use the suite's existing test
framework — inspect the top of `keiro/test/Main.hs` to match tasty/hspec style and imports):

- `category "incident"` → `Right (Category "incident")`.
- `category ""` → `Left CategoryEmpty`.
- `category "hospital-surge"` → `Left (CategoryContainsSeparator "hospital-surge")`.
- `category "$all"` → `Left (CategoryReserved "$all")`.
- `category "hospital:surge"` → `Right …` (the `:` sub-namespace convention is allowed).
- `streamName (entityStream (categoryUnsafe "incident") "inc_01h")` ==
  `StreamName "incident-inc_01h"`.
- `entityStreamId (categoryUnsafe "orders") (OrderId 100)` renders `"orders-…"` using a local
  `StreamIdSegment` instance (or `entityStream … (Text.pack (show …))`).
- **Round-trip property:** for the produced stream name, Kiroku's own accessor
  `Store.categoryName (streamName (entityStream cat id))` equals `categoryName cat`, including
  the case where the id segment itself contains a `-` (e.g. id `"a-b"` ⇒ name `"orders-a-b"` ⇒
  category still `"orders"`). Assert against `Store.categoryName` (from #55), **not** a
  reimplemented `takeWhile (/= '-')` — that is the whole point of the split.

Acceptance: `cabal test keiro-test` passes, with the new group visible in the output.

### Milestone 3 — Adopt in the in-repo example + reconcile compound categories

Scope: prove the API on real call sites inside the keiro repo and standardize the compound-
category convention surfaced in Surprises.

- In `keiro/jitsurei/` (the in-repo example package), replace hand-concatenated stream names
  with module-level `Category` values + `entityStream`/`entityStreamId`. Concretely, the
  `"chapter-" <> … <> "-" <> …` name in `keiro/jitsurei/app/Main.hs:382` is itself a *compound*
  case: a chapter is keyed by `(member, chapter)`, so its category should be `chapter` with a
  composite id segment `"<member>:<chapter>"` (use `:` inside the id, `-` only as the
  category boundary), or model it explicitly as a sub-namespace — record the choice in the
  Decision Log.
- Reconcile the `wf:` workflow helper with the API: either re-express
  `workflowStreamName` in terms of `entityStream (categoryUnsafe ("wf:" <> name)) wid`, or, at
  minimum, validate that `name` contains no `-` (today a hyphenated `WorkflowName` silently
  shifts the category — see Surprises). Pick one and document it.
- Reconcile the saga prefix: `SagaRef.sagaStreamPrefix` in
  `keiro-dsl/src/Keiro/Dsl/Grammar.hs:397-405` currently carries a raw trailing-`-` string. At
  minimum, add validation/documentation that a compound saga family must use `:` (e.g.
  `hospital:surge`) rather than `hospital-surge-` to keep its own category. Updating the DSL
  parser/scaffold to enforce this is in scope here only if low-risk; otherwise split into a
  follow-up item under Progress.

Acceptance: the in-repo example builds and its tests pass:
`cabal build jitsurei && cabal test` (the relevant in-repo example/test targets). Any newly
chosen conventions are recorded in the Decision Log and reflected in the example.

### Milestone 4 (cross-repo, optional) — Migrate `keiro-runtime-jitsurei` services

Scope (in the separate repo `/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei`, after the
new `keiro-core` is available to it): for each aggregate module
(`services/**/EventStream.hs`), replace the two hand-concat functions and the local `idText`
with one module-level `Category` plus an `entityStreamId`-based definition, and add one
`StreamIdSegment` instance per id type:

```haskell
incidentCategory :: Category IncidentEventStream
incidentCategory = categoryUnsafe "incident"

instance StreamIdSegment IncidentId where renderIdSegment = Text.pack . show

incidentStream :: IncidentId -> Stream IncidentEventStream
incidentStream = entityStreamId incidentCategory

incidentCommandStream :: IncidentId -> Stream IncidentCommand
incidentCommandStream = entityStreamId (coerceCategory incidentCategory)  -- or its own value
```

For the compound process-manager streams (`hospital-surge-…`, `incident-escalation-…`), switch
to `:` sub-namespaced categories (`hospital:surge`, `incident:escalation`) so each gets its own
category — and note in that repo's changelog that this is a **stream-name change** (existing
data under the old names would need migration; flag it, do not silently rename live streams).

Acceptance: `keiro-runtime-jitsurei` builds and its test-suites pass against the new
`keiro-core`. (This milestone may be tracked as its own ExecPlan in that repo.)


## Concrete Steps

Run everything from `/Users/shinzui/Keikaku/bokuno/keiro` inside the project dev shell.

1. Confirm starting state builds:
   ```bash
   cabal build keiro-core
   ```
   Expected: `keiro-core` compiles (it does at HEAD).

2. **M1** — edit `keiro-core/src/Keiro/Stream.hs` as described, then:
   ```bash
   cabal build keiro-core
   ```
   Expected transcript (abridged):
   ```text
   [1 of 1] Compiling Keiro.Stream ( … )
   ```
   with no warnings. Sanity-check the new symbols resolve, e.g. via `cabal repl keiro-core`:
   ```bash
   cabal repl keiro-core
   ```
   ```text
   ghci> :t entityStream
   entityStream :: Category a -> Text -> Stream a
   ghci> Keiro.Stream.category "hospital-surge"
   Left (CategoryContainsSeparator "hospital-surge")
   ghci> Keiro.Stream.streamName (entityStream (categoryUnsafe "incident") "inc_1")
   StreamName "incident-inc_1"
   ```

3. **M2** — add the test group to `keiro/test/Main.hs`, then:
   ```bash
   cabal test keiro-test
   ```
   Expected: all tests pass, including the new `Keiro.Stream` group (the round-trip property and
   the four validation cases).

4. **M3** — migrate `keiro/jitsurei` and reconcile `wf:`/saga conventions, then:
   ```bash
   cabal build all
   cabal test keiro-test
   ```
   Expected: build clean; example and conformance tests pass. Re-run the DSL conformance suites
   if the saga/scaffold path was touched:
   ```bash
   cabal test
   ```

5. Commit after each milestone (see Validation for the commit-message/trailer format).


## Validation and Acceptance

- **M1 effective beyond compilation:** the `cabal repl` transcript in Concrete Steps shows the
  smart constructor *rejecting* a hyphenated category and `entityStream` rendering the expected
  `"<category>-<id>"`. This is the behavioral proof that the footgun (hazard #2) is now caught.
- **M2:** `cabal test keiro-test` passes; the new group includes the round-trip property
  `Store.categoryName (streamName (entityStream cat id)) == categoryName cat` for ids with and
  without an embedded `-`. Because the left side is kiroku's own accessor (#55), this proves the
  API's category is *exactly* the store's category, not a keiro-local copy of the rule.
- **M3:** the in-repo example builds and runs; no stream name produced by the migrated code
  differs from the pre-migration name for the *aggregate* cases (the rename is intentional only
  for the compound saga/PM cases, which must be called out). Diff the produced names before/after
  for at least one aggregate to confirm byte-for-byte equality on the non-compound path.

Every commit made under this plan must carry both trailers:

```text
feat(keiro-core): add Category API for safe stream construction

ExecPlan: docs/plans/66-add-safe-stream-construction-helpers-category-api-to-keiro-stream.md
Intention: intention_01ktrvackbe7jrenk79j8jgb5e
```


## Idempotence and Recovery

- M1/M2 are pure additions to source and tests; re-running `cabal build`/`cabal test` is safe
  and repeatable. Reverting is a single `git revert` of the commit.
- M3/M4 change *stream names* only for the compound saga/process-manager cases. Renaming a live
  stream is **not** reversible against existing data — for any environment with persisted
  streams, treat a category rename as a data migration, not a code edit. On the non-compound
  aggregate path the names are unchanged (validated in M3), so adoption there is a safe no-op
  for data.
- If `categoryUnsafe` is ever reached with an invalid literal it fails fast at process startup
  (top-level `error`) rather than producing a mis-categorized stream; this is the intended,
  recoverable-by-fixing-the-literal failure mode.


## Interfaces and Dependencies

Dependencies (already present in `keiro-core.cabal`): `text` (for `Text`, `Text.isInfixOf`,
`Text.pack`), `kiroku-store` (for `StreamName (..)`, `CategoryName (..)`, and now
`categoryName`/`streamNameInCategory` from `Kiroku.Store.Types`), `generic-lens`/`lens`
(existing). No *new package* is added, but the `kiroku-store` **lower bound is bumped** to the
version that ships ExecPlan #55's API; #66 cannot build until #55 has landed and that bound is
raised.

Public surface that must exist at the end of **M1**, in
`keiro-core/src/Keiro/Stream.hs` (module `Keiro.Stream`):

```haskell
newtype Category a = Category { categoryTextOf :: Text }
data    CategoryError = CategoryEmpty | CategoryContainsSeparator !Text | CategoryReserved !Text

category      :: Text -> Either CategoryError (Category a)
categoryUnsafe :: Text -> Category a
categoryName  :: Category a -> CategoryName              -- re-exported from Kiroku.Store.Types

class StreamIdSegment i where renderIdSegment :: i -> Text
instance StreamIdSegment Text
instance StreamIdSegment String

entityStream   :: Category a -> Text -> Stream a
entityStreamId :: StreamIdSegment i => Category a -> i -> Stream a

-- re-exported alongside existing Stream (..), stream, streamName, mapStreamName:
-- CategoryName (..)
```

Invariants the implementation must uphold:

- For all `cat :: Category a` and `i`, the Kiroku category of `streamName (entityStreamId cat i)`
  (i.e. text before the first `-`) equals `categoryTextOf cat`.
- `category` rejects `""`, any text containing `-`, and exactly `"$all"`.
- `entityStream`/`entityStreamId` do not perform their own escaping of the id segment; the id may
  contain `-`/`:` (the store accepts them) and the leading category is still parsed correctly.

Consumers that will adopt the surface: `keiro/jitsurei` (M3), the workflow helper
`Keiro.Workflow.Types.workflowStreamName` (M3, reconciliation), the DSL saga prefix
`Keiro.Dsl.Grammar.SagaRef` (M3, validation), and the `keiro-runtime-jitsurei` aggregate
modules (M4).


## Revision Notes

- **2026-06-10 — Split the convention-owning core into kiroku-store (ExecPlan #55).** Original
  draft placed the entire Category API, including the category rule, in `keiro-core`. Inspection
  of kiroku showed the "category = `split_part(stream_name,'-',1)`" rule is owned and enforced by
  the store's schema (generated column) and re-derived in
  `Kiroku.Store.Notification.categoryFromPayload`, with a comment requiring the two to stay in
  sync — so reimplementing it in keiro's round-trip test would be a third copy and a drift
  hazard. Per a design decision with the requester, the mechanical/permissive accessor
  (`categoryName :: StreamName -> CategoryName`) and constructor (`streamNameInCategory`) now
  live in kiroku-store ExecPlan #55; this plan's `entityStream` delegates to
  `streamNameInCategory`, the M2 round-trip test asserts against kiroku's `categoryName`, a new
  M0 records the #55 dependency and the `kiroku-store` lower-bound bump, and the Purpose,
  Decision Log, Validation, and Interfaces sections were updated to match. The opinionated,
  phantom-typed, rejecting layer (`Category a`, validation, `entityStream`/`entityStreamId`)
  remains in keiro-core.
