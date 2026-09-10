---
id: 275
slug: add-cursor-paged-workflow-inspection-reads-for-the-http-surface
title: "Add cursor-paged workflow inspection reads for the HTTP surface"
kind: exec-plan
created_at: 2026-09-10T01:38:10Z
intention: "intention_01m24f03zreg59e5twbm7mpmga"
---

# Add cursor-paged workflow inspection reads for the HTTP surface

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change an operator tool — the planned browser UI first, `keiro-ops` today — can
browse a Keiro deployment's durable workflows the way a person actually looks at them: page
through thousands of workflow instances by a documented status vocabulary, workflow type, and
creation or update window; open one instance and read its header; then scroll its journal,
its step index, its children, and its awakeables one bounded page at a time. Every page
carries an opaque continuation token, omits that token on the last page, and is served by
supported `keiro` library functions rather than by SQL that a caller writes against Keiro's
private tables.

This implements the library half of
[IR-30, Complete workflow inspection primitives for HTTP](../improvement-requests/complete-workflow-inspection-primitives-for-http.md).
IR-30 is one of the requests filed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui`). The HTTP endpoints that will wrap these reads belong to the
sister package requested by `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26`,
which does not exist yet; this plan produces the reads, their canonical JSON rendering, the
status vocabulary, and the cursor contract so that the IR-26 plan can wrap them mechanically.
Live refresh belongs to `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-27`; these
reads are the authoritative poll path that any push feed re-reads, and every page reports the
server clock it was observed at so a feed can reconcile against it.

You can see it working by running the new test group, by running `keiro-ops wf show` against
a test database and observing that its `instance` JSON now carries `status_class`, and by
paging a seeded ledger with the new `Keiro.Workflow.Inspection` functions from `cabal repl`.


## Progress

- [ ] Milestone 1: opaque cursor codec, status-class vocabulary, and the bounded instance
      listing over `keiro_workflows` in key order and creation order, with the legacy
      `listWorkflowInstances` re-based onto the shared statements.
- [ ] Milestone 2: migration `0033.sql` adding `keiro_workflows_created_idx`, the
      migration-suite bookkeeping, and the index-usage proof.
- [ ] Milestone 3: paged detail reads (journal, step index, children, awakeables) with
      generation resolution, exercised against a real workflow instance.
- [ ] Milestone 4: canonical JSON rendering in the library and `keiro-ops` adoption
      (`wf show`, `wf steps`, `wf journal`), including the header-agreement diff test.
- [ ] Milestone 5: documentation, changelogs, ADR-28 update, IR-30 evidence, and the full
      verification gate.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Scope this plan to the owning library (`keiro`) plus `keiro-ops` adoption; do
  not create the HTTP sister package or any endpoint here.
  Rationale: IR-30 asks for endpoints "in the IR-26 sister package", and no plan or package
  for IR-26 exists in this repository (`grep -rl 'IR-26' docs/plans docs/masterplans` is
  empty). Building endpoints would mean building that package under this plan's number,
  which is IR-26's scope. The reads, their JSON rendering, and the cursor contract are
  designed so an endpoint is a one-line wrapper; the hand-off contract is written down in
  Interfaces and Dependencies.
  Date: 2026-09-10

- Decision: The wire rendering of every inspection type (snake_case JSON objects, `items`
  plus optional `next_cursor` envelopes) lives in `keiro`, in `Keiro.Workflow.Inspection`,
  and `keiro-ops` renders its `--json` output through those functions.
  Rationale: IR-30's acceptance requires the header read to agree with
  `keiro-ops wf show --json` and IR-26 requires endpoint bodies to equal the CLI's
  `jsonValue`. Two hand-written renderings drift; one library-owned rendering makes the
  agreement hold by construction and leaves a single frozen wire shape for the HTTP layer
  to reuse. Published CLI keys are preserved; the only change to existing output is the
  additive `status_class` key on instances and `recorded_at` on step rows.
  Date: 2026-09-10

- Decision: The status vocabulary is a seven-value partition of the instance row —
  `running`, `retrying`, `sleeping`, `awaiting`, `completed`, `cancelled`, `failed` — derived
  purely from stored columns (`status`, `attempts`, `wake_after`) with no clock input.
  Rationale: A filter that depends on "now" (lease live, retry due, sleep due) cannot be a
  stable vocabulary because the same row answers differently from one second to the next
  and cannot be checked against the Haskell classifier in a test. Time-relative facets are
  exposed as raw timestamps beside an `observed_at` server clock reading, so clients derive
  "due" against one consistent clock. IR-30's "stuck (retries exhausted)" case is `failed`
  (the resume worker records `WorkflowFailed` when `maxAttempts` is reached); its "awaiting
  signal" case is `awaiting`; its "stuck-retrying" case is `retrying`.
  Date: 2026-09-10

- Decision: Cursors are opaque text tokens minted and parsed by the library
  (`Keiro.Inspection.Cursor`): base64url without padding over a compact JSON object carrying
  a kind tag and the keyset payload. A token is accepted only for the read kind and ordering
  it was minted for; filters are not encoded and a client that changes filters restarts.
  Rationale: The keiro-ui wire conventions (`mori://shinzui/keiro-ui`,
  `docs/architecture/inspection-api-conventions.md`, artifact-level URI pending) require
  cursors the UI never does arithmetic on. Library ownership guarantees the CLI, the HTTP
  layer, and the sibling process-manager plan (`docs/plans/274-expose-process-manager-inspection-reads.md`)
  mint interchangeable tokens. `base64-bytestring` 1.2.1.0 is already in the build closure,
  so the dependency adds nothing to the install plan.
  Date: 2026-09-10

- Decision: Add one migration, `0033.sql`, creating
  `keiro_workflows_created_idx ON keiro.keiro_workflows (created_at, workflow_name, workflow_id)`,
  and offer a second listing order, newest-created first, served by that index.
  Rationale: The only existing total order is the primary key `(workflow_name, workflow_id)`,
  which is useless as a UI default ("show me what started recently") and gives creation
  windows no index. `created_at` is immutable, so a keyset over
  `(created_at, workflow_name, workflow_id)` never skips or repeats even under concurrent
  updates; `updated_at` is deliberately not a sort key because it moves. The index is
  written once per instance insert and never touched by status or lease updates. `updated_*`
  windows are offered as plain row filters and documented as unindexed.
  Date: 2026-09-10

- Decision: Every paged read fetches `pageSize + 1` rows and reports a continuation only
  when the extra row exists; page sizes are validated to `1..500` and out-of-range sizes
  return `InvalidPageSize` rather than clamping.
  Rationale: The conventions require `next_cursor` to be omitted on the last page even when
  that page is full; fetching one extra row is the only way to know without a second query.
  Validation rather than clamping follows the timer-read precedent in
  [ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  (a silently clamped page is a lie to the caller).
  Date: 2026-09-10

- Decision: `keiro-ops wf list` keeps its exact behavior and JSON array shape and does not
  gain class or cursor flags in this plan. `wf show`, `wf steps`, and `wf journal` adopt the
  library reads without changing their shapes (beyond the additive keys above).
  Rationale: IR-30 says the CLI's one-shot behavior is not in question, and ADR-28 says
  scripts depend on the structured JSON. An envelope with `next_cursor` cannot be added to an
  array without breaking it, and a bounded page size would break `--limit` values above the
  cap. `wf show` adoption removes an N+1 query pattern (it currently loads every generation's
  step index and looks up each awakeable individually); `wf steps` and `wf journal` adoption
  deletes duplicated decode code.
  Date: 2026-09-10

- Decision: A journal page raises `WorkflowJournalDecodeError` when an event cannot be decoded
  with `workflowJournalCodec`, exactly as the runtime's replay path does.
  Rationale: The journal is runtime-owned data; an undecodable event is corruption, and the
  CLI already fails the whole `wf journal` command in that case. Returning half-decoded pages
  would invite a UI to render corruption as history.
  Date: 2026-09-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What a durable workflow is, and the four tables behind it

A durable workflow in Keiro is an ordinary Haskell computation whose named steps are
journaled to a kiroku event stream so it can crash and resume without redoing finished work.
The authoring surface is `keiro/src/Keiro/Workflow.hs`. Four durable structures matter here,
all in the `keiro` PostgreSQL schema owned by `keiro-migrations`:

- The **journal** is a kiroku stream per instance and generation:
  `wf:<name>-<id>` for generation 0 and `wf:<name>-<id>#<g>` for a rotated generation `g`
  (`workflowGenerationStreamName` in `keiro/src/Keiro/Workflow/Types.hs`). Its events are
  `WorkflowJournalEvent` values encoded by `workflowJournalCodec`. A **generation** is one
  physical journal; `continueAsNew` rotates a long-running workflow onto the next one, and
  `currentGeneration` in `keiro/src/Keiro/Workflow/Schema.hs` returns the highest one recorded.
- The **step index** `keiro.keiro_workflow_steps` (created by
  `keiro-migrations/migrations/0005-keiro-workflow-steps.sql`, re-keyed by `0008`) mirrors
  every journaled step as a row keyed by `(workflow_id, workflow_name, generation, step_name)`
  with the JSON `result` and `recorded_at`. `Keiro.Workflow.Schema.loadStepIndex` reads a
  whole generation as a `Map`.
- The **instance row** `keiro.keiro_workflows` (migrations `0011`, `0012`, `0013`, `0021`) is
  one row per logical instance keyed by `(workflow_id, workflow_name)` holding `generation`,
  `status`, `attempts`, `last_error`, `next_attempt_at`, `wake_after`, `leased_by`,
  `lease_expires_at`, `created_at`, `updated_at`, `completed_at`. It is the **wake ledger**:
  per [ADR-23](../adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md)
  every wake-source transition writes it, and the resume worker discovers work from it alone.
  `Keiro.Workflow.Instance` (`keiro/src/Keiro/Workflow/Instance.hs`) owns `WorkflowInstanceRow`,
  `lookupInstance`, and the existing keyset `listWorkflowInstances`; the shared status codec
  and upsert live one level down in `keiro/src/Keiro/Workflow/Instance/Schema.hs`. Indexes:
  the primary key, `keiro_workflows_active_idx (status, wake_after) WHERE status IN ('running','suspended')`,
  and `keiro_workflows_gc_idx (status, completed_at)`.
- **Children** `keiro.keiro_workflow_children` (migrations `0007`, `0020`) link a child
  instance to its parent with `await_step`, `status`, `result`, `failure_reason`, and
  timestamps; `keiro/src/Keiro/Workflow/Child/Schema.hs` owns `ChildRow` and
  `lookupChildrenOfParent` (index `keiro_workflow_children_parent_idx (parent_id, parent_name)`).
- **Awakeables** `keiro.keiro_awakeables` (migration `0006`) are external promises a workflow
  suspends on; `keiro/src/Keiro/Workflow/Awakeable/Schema.hs` owns `AwakeableRow` and
  `lookupAwakeable` by id (index `keiro_awakeables_owner_idx (owner_workflow_name, owner_workflow_id)`).

The lifecycle that produces the row values is in `keiro/src/Keiro/Workflow/Resume.hs`: the
resume worker claims an instance with a time-limited **lease** (`leased_by`,
`lease_expires_at`), a crash bumps `attempts` and pushes `next_attempt_at` out along an
exponential backoff, durable progress resets `attempts` to zero, and reaching `maxAttempts`
appends `WorkflowFailed`, which sets `status = 'failed'`. A workflow parked on a sleep timer
is `suspended` with `wake_after` set; one parked on an awakeable or a child is `suspended`
with `wake_after` null and is invisible to discovery until its wake source flips the row.

### What exists today and what is missing

`keiro-ops/src/Keiro/Ops/Workflow.hs` already exposes `wf list` (keyset by
`(workflow_name, workflow_id)` through `listWorkflowInstances`), `wf show` (header plus all
children plus awakeables discovered by scanning every generation's step index for `awkid:`
steps and looking each up), `wf steps` (the whole step map of one generation), and
`wf journal` (the whole journal of one generation, read in 256-event loops through
`Kiroku.Store.Read.readStreamForward` and decoded by a private `decodeJournalView`). Every
command renders into `OpsResult { headers, rows, jsonValue }` from
`keiro-ops/src/Keiro/Ops/Render.hs`, and the JSON key names (`workflow_id`, `workflow_name`,
`generation`, `status`, `attempts`, `last_error`, `next_attempt_at`, `wake_after`,
`leased_by`, `lease_expires_at`, `created_at`, `updated_at`, `completed_at`; `child_id`,
`child_name`, `parent_id`, `parent_name`, `await_step`, `result`, `failure_reason`;
`awakeable_id`, `owner_workflow_name`, `owner_workflow_id`, `payload`; `event_id`,
`event_type`, `stream_version`, `global_position`, `step_name`, `recorded_at`; `step`)
are the published shapes this plan must preserve.

What is missing, in IR-30's words: a status vocabulary richer than the five stored statuses;
listings by age window; a continuation signal (the current list returns a bare list and the
caller cannot tell whether a next page exists); and bounded, independently paged reads of
the journal, steps, children, and awakeables.

### Terms used in this plan

A **keyset cursor** is a continuation that names the last row's sort key, so the next page
is "rows strictly after this key in this ordering". Unlike an `OFFSET`, it costs the same for
page one and page one thousand and never skips or repeats rows whose keys do not change. An
**opaque cursor** is a keyset cursor serialized to text that the client echoes back without
interpreting. A **status class** is one of the seven vocabulary values this plan defines,
computed from an instance row. **Observed-at** is the server clock reading taken just before
a page is read; clients compare time-relative fields against it rather than their own clock.

### Relevant ADRs

- [ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  is the governing rule: operator surfaces wrap supported library operations, a missing
  primitive is added and tested in the owning library first, and keiro surfaces use the
  fixed position vocabulary (`store_position`, `visible_store_head`, "global position
  distance"; never "lag" or "backlog"). Its timer paragraph (bounded pages, literal filters,
  a page is an observation not a snapshot) is the precedent this plan follows for workflows,
  and this plan extends that paragraph.
- [ADR-23](../adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md)
  makes `keiro_workflows` authoritative for status, and explains why the discovery predicate
  is stated positively so the partial active index can serve it. The class filter here passes
  the implied stored statuses as a separate positive predicate for the same reason.
- [ADR-6](../adr/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md),
  [ADR-8](../adr/0008-workflow-failure-history-is-immutable-and-derived-terminal-state-is-revivable.md),
  and [ADR-27](../adr/0027-workflow-lifecycle-markers-are-append-only-and-first-writer-wins.md)
  define what the rows and journal mean (awakeable and child rows are the durable lifecycle
  authority; failure history is immutable and `failed` is revivable; lifecycle markers are
  first-writer-wins). The reads here observe those artifacts and never write them.
- Cross-repository: `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3` (push is a hint,
  poll is truth) is why pages carry `observed_at` and why nothing here depends on NOTIFY;
  `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4` (surfaces live in sister packages) is
  why no web dependency enters `keiro`. The conventions document is project
  `mori://shinzui/keiro-ui`, path `docs/architecture/inspection-api-conventions.md`
  (artifact-level URI pending); its rules used here are snake_case fields, `items` plus an
  omitted-on-last-page `next_cursor`, and opaque cursors.

The ADR bundle at `docs/adr/` is profile-governed (`docs/adr/profile.dhall`), so editing
ADR-28 requires advancing its `timestamp`, appending to `docs/adr/log.md` with `okf log add`,
and passing the strict validation command in Concrete Steps. No ADR documents a workflow
inspection vocabulary or cursor contract today.

### Related plans

`docs/plans/270-expose-reason-bearing-dead-timer-inspection-and-bounded-reads.md` shipped the
bounded timer reads whose conventions (validate page size, `LIMIT n+1`, immutable keys,
observation semantics, read-only proof by column comparison) this plan reuses.
`docs/plans/274-expose-process-manager-inspection-reads.md` is the sibling plan for IR-29
and was still an empty skeleton when this plan was written; it should reuse
`Keiro.Inspection.Cursor` and the page conventions defined here rather than inventing its own.

### Test infrastructure

`keiro/test/Main.hs` runs Hspec through `withMigratedSuite` from
`keiro-test-support/src/Keiro/Test/Postgres.hs` (one migrated template database per suite,
cloned into a fresh database per example, so examples never share rows) and groups workflow
tests under `describe "Keiro.Workflow ..."`. Existing helpers to reuse: `insertWorkflowInstanceStmt`
and `explainDiscoveryStmt` near line 16742 (the `EXPLAIN` proof pattern with
`SET LOCAL enable_seqscan = off`), `parentWorkflow`/`shipWorkflow` (a parent that spawns a
child), and `approvalFlowWithId` (a workflow that allocates an awakeable and suspends).
`keiro-ops/test/Main.hs` has `opsEnv`, `seedStep`, `expectStore`, `firstWorkflowId`, and
`journalEventCount`, and runs commands directly through `OpsWorkflow.runCommand`.
`keiro-migrations/test/Main.hs` checks the manifest, the sha256 lockfile
`keiro-migrations/migrations.native.lock`, and the native schema snapshot
`keiro-migrations/expected-schema/native/keiro-v18.txt`, and hard-codes the migration count
in three test titles and in `nativeMigrationFiles`.


## Plan of Work

### Milestone 1: Cursor codec, status vocabulary, and the bounded instance listing

At the end of this milestone a caller can page `keiro_workflows` in primary-key order or
newest-created-first with a documented class filter, name filter, and creation or update
windows, receiving an opaque continuation token that is absent on the last page. Both
orderings are correct here; the index that makes the creation ordering fast arrives in
Milestone 2. The legacy `listWorkflowInstances` still exists with its exact signature and
behavior but runs on the same SQL, so there is one listing implementation.

Create `keiro/src/Keiro/Inspection/Cursor.hs` (add it to `exposed-modules` in
`keiro/keiro.cabal`, and add `base64-bytestring >=1.2 && <1.3` to the library
`build-depends`). It defines `InspectionCursor` (a newtype over `Text` whose constructor is
exported so the HTTP layer and CLI can carry it, but whose contents are documented as opaque),
`CursorError`, `encodeCursor`, and `decodeCursor`. Encoding builds the compact JSON object
`{"k":<kind>,"v":<payload>}` with `Data.Aeson.encode`, then applies
`Data.ByteString.Base64.URL.encodeUnpadded` and decodes the bytes as `Text`. Decoding reverses
that, rejects any base64 or JSON failure as `MalformedCursor`, and rejects a kind tag other
than the one the caller expects as `CursorKindMismatch expected actual`. Keep the kind tags
as plain text constants in the modules that own each read (`"wf-key"`, `"wf-created"`,
`"wf-steps"`, `"wf-journal"`, `"wf-children"`, `"wf-awakeables"`).

Create `keiro/src/Keiro/Workflow/Inspection.hs` (exposed). In this milestone it holds the
status vocabulary and the instance listing; later milestones add the detail pages and the
JSON rendering. Define `WorkflowStatusClass` with seven constructors and two total codecs,
`statusClassToText` and `statusClassFromText :: Text -> Maybe WorkflowStatusClass`, whose
tokens are exactly `running`, `retrying`, `sleeping`, `awaiting`, `completed`, `cancelled`,
`failed`. Define `statusClassOf :: WorkflowInstanceRow -> WorkflowStatusClass` as: status
`WfRunning` with `attempts == 0` is `running`; `WfRunning` otherwise is `retrying`;
`WfSuspended` with `wakeAfter` present is `sleeping`; `WfSuspended` otherwise is `awaiting`;
the three terminal statuses map to their own class. Define
`classStatus :: WorkflowStatusClass -> WorkflowStatus` (the stored status each class implies)
so the SQL can carry a positive `status = ANY(...)` predicate beside the class predicate.

Define the query and page records exactly as written in Interfaces and Dependencies
(`WorkflowListOrdering`, `WorkflowListQuery`, `defaultWorkflowListQuery`, `WorkflowListPage`,
`InspectionError`) and `listWorkflowInstancesPage`. The function validates `pageSize` against
`maxInspectionPageSize = 500`, decodes the cursor with the kind tag for the requested ordering
(`wf-key` or `wf-created`), reads `getCurrentTime` for `observedAt`, runs the statement for
the requested ordering with `LIMIT pageSize + 1`, and returns the first `pageSize` rows plus
a cursor minted from the last returned row's key only when the extra row was present.

In `keiro/src/Keiro/Workflow/Instance.hs`, replace `listWorkflowInstancesStmt` with two
statements, one per ordering, built by concatenating one shared filter fragment (parameters
`$1` to `$7` below) with an ordering-specific cursor predicate, `ORDER BY`, and `LIMIT`. The
`ByKey` statement is:

```sql
WHERE ($1::text[] IS NULL OR status = ANY($1))
  AND ($2::text[] IS NULL OR
       CASE
         WHEN status = 'running' AND attempts = 0 THEN 'running'
         WHEN status = 'running' THEN 'retrying'
         WHEN status = 'suspended' AND wake_after IS NOT NULL THEN 'sleeping'
         WHEN status = 'suspended' THEN 'awaiting'
         ELSE status
       END = ANY($2))
  AND ($3::text IS NULL OR workflow_name = $3)
  AND ($4::timestamptz IS NULL OR created_at >= $4)
  AND ($5::timestamptz IS NULL OR created_at <  $5)
  AND ($6::timestamptz IS NULL OR updated_at >= $6)
  AND ($7::timestamptz IS NULL OR updated_at <  $7)
  AND ($8::text IS NULL OR (workflow_name, workflow_id) > ($8, $9))
ORDER BY workflow_name, workflow_id
LIMIT $10
```

The `ByCreatedDesc` statement uses the same first seven parameters, the cursor predicate
`($8::timestamptz IS NULL OR (created_at, workflow_name, workflow_id) < ($8, $9, $10))`,
`ORDER BY created_at DESC, workflow_name DESC, workflow_id DESC`, and `LIMIT $11`. Its cursor
payload is the triple `(created_at, workflow_name, workflow_id)`; aeson's `UTCTime` instance
round-trips microsecond values exactly and the tuple comparison happens in SQL at
`timestamptz` precision, so no drift is possible.

The `CASE` expression must be the SQL twin of `statusClassOf`; a test in this milestone
proves they agree on every fixture row. Keep the legacy `listWorkflowInstances` signature and
`WorkflowInstanceFilter` record unchanged: implement it by mapping each requested
`WorkflowStatus` to the classes it implies (`WfRunning` to `running` and `retrying`,
`WfSuspended` to `sleeping` and `awaiting`, terminal statuses one-to-one), passing no time
windows, and passing the caller's page size unbounded as before. Windows are half-open:
`since` is inclusive, `before` is exclusive.

Add a new `describe "Keiro.Workflow.Inspection"` group to `keiro/test/Main.hs` with these
examples, seeding rows through `Instance.upsertInstanceTx` plus direct column updates
(a private test statement may set `attempts`, `wake_after`, `created_at`, and `updated_at`;
tests may write SQL against the fixture database, library code may not):

1. "classifies every row the same way in Haskell and SQL": seed one row per class (running
   with attempts 0; running with attempts 2 and `next_attempt_at` in the future; suspended
   with `wake_after`; suspended without; completed; cancelled; failed). For each class, list
   with `classes = Just (class :| [])` and assert every returned row satisfies
   `statusClassOf row == class`; assert the union over all seven classes equals the full
   ledger and the classes are pairwise disjoint.
2. "pages the ledger completely and stably in key order": seed 23 instances across three
   names; page with `pageSize = 5`; assert the concatenation equals the full key-ordered
   list with no duplicates, the fifth page has three rows and no cursor. Then seed 20 rows
   and page with `pageSize = 5` again: the fourth page is full and its `nextCursor` is
   `Nothing` (the `LIMIT n+1` probe found nothing).
3. "rejects invalid page sizes and foreign or malformed cursors": sizes 0, 501, and
   `maxBound` yield `InvalidPageSize`; the text `"not-a-cursor"` yields
   `InvalidCursor (MalformedCursor _)`; a token minted by another kind (use
   `encodeCursor "wf-steps" ...` directly) and a `ByKey` token passed under `ByCreatedDesc`
   both yield `InvalidCursor (CursorKindMismatch _ _)`.
4. "observes then-current rows behind and ahead of a cursor": take page one, then insert
   a row whose key sorts before the cursor and one that sorts after; page two contains the
   latter and not the former.
5. "applies half-open creation and update windows": three rows with `created_at` at
   `t`, `t + 1h`, `t + 2h`; `createdSince = t + 1h` returns two; `createdBefore = t + 1h`
   returns one; the same for `updated_*`.
6. "is read-only": capture every row with `lookupInstance` before and after all listing calls
   and assert equality, and assert `findUnfinishedWorkflowIds` returns the same set.
7. "keeps the legacy listing byte-identical": the existing
   "lists workflow instances with filters and stable keyset pages" example in the
   `Keiro.Workflow instance table` group must still pass unchanged.
8. "finds a stuck failed instance through the vocabulary alone": claim an instance with
   `claimInstance` (lease now held), then upsert it to `WfFailed` with a `last_error`; a
   listing with `classes = Just (ClassFailed :| [])` returns it, and its `leasedBy` is still
   set. This is IR-30 acceptance item 4.
9. "pages newest-created first completely and stably": seed 12 rows with distinct
   `created_at` values one minute apart; page with `pageSize = 5` under `ByCreatedDesc`;
   assert strictly descending `createdAt`, complete coverage, no duplicates, and no cursor
   on the third page.

Run the focused command in Concrete Steps; all examples pass and the pre-existing workflow
groups are unaffected.

### Milestone 2: The creation-order index

At the end of this milestone the creation ordering and creation windows from Milestone 1 are
served by an index, proven by `EXPLAIN`, and the migration suite, lockfile, and native
schema snapshot include migration 0033.

Create the migration through the standard tool so the manifest is appended consistently:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
nix develop -c cabal run keiro-migrate -- new \
  --manifest keiro-migrations/migrations/manifest \
  --description "add workflow instance creation-order index"
```

The tool creates `keiro-migrations/migrations/0033.sql` with the description as its first
comment line and appends `0033.sql` to `keiro-migrations/migrations/manifest`. Replace the
body with:

```sql
-- add workflow instance creation-order index
-- Creation-order listing and creation windows for workflow inspection reads.
-- created_at is immutable, so a keyset over (created_at, workflow_name,
-- workflow_id) never skips or repeats under concurrent status or lease updates,
-- and a backward scan of this index serves the newest-first ordering.
CREATE INDEX IF NOT EXISTS keiro_workflows_created_idx
  ON keiro.keiro_workflows (created_at, workflow_name, workflow_id);
```

Append the checksum line and regenerate the snapshot:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations/migrations
shasum -a 256 0033.sql >> ../migrations.native.lock
cd /Users/shinzui/Keikaku/bokuno/keiro
KEIRO_REGENERATE_EXPECTED_SCHEMA=1 nix develop -c cabal test keiro-migrations-test \
  --test-options='--match "checked-in snapshot"'
git diff --stat keiro-migrations/expected-schema/native/keiro-v18.txt
```

The `keiro-migrate new` command (from `mori://shinzui/pg-migrate`) names the file with the
next zero-padded number, seeds it with the description as a comment line, and appends it to
the manifest. The lockfile format is `<sha256><two spaces><file name>`, which is what
`shasum -a 256` prints when run inside the directory. The snapshot diff must show exactly one
added index line for `keiro_workflows_created_idx`. In `keiro-migrations/test/Main.hs`
change the three titles that say thirty-two or 32 to thirty-three and 33, append
`"0033.sql"` to `nativeMigrationFiles`, and add an example under
`describe "fresh native databases"` named "0033 adds the creation-order index" that applies
the plan to a fresh database, asserts
`SELECT indexdef FROM pg_indexes WHERE indexname = 'keiro_workflows_created_idx'` returns
`CREATE INDEX keiro_workflows_created_idx ON keiro.keiro_workflows USING btree (created_at, workflow_name, workflow_id)`,
and inserts and reads back one instance row to show the table is unaffected. Add an
Unreleased entry to `keiro-migrations/CHANGELOG.md` in the style of the 0.16.0.0 entry for
0032.

Add one test to the inspection group, "plans the creation-order listing through
keiro_workflows_created_idx": mirror the discovery-index example (`SET LOCAL enable_seqscan = off`,
then `EXPLAIN (FORMAT TEXT)` of the literal `ByCreatedDesc` query with a bound creation window
and the DESC ordering) and assert the plan text contains `keiro_workflows_created_idx`; then
`EXPLAIN` the same query with only a `created_at >= ...` window and the key ordering and
assert the index is still named, because the window alone is served by it. The test carries
its own literal SQL, as the discovery test does, so the library statement text stays private.

### Milestone 3: Paged detail reads

At the end of this milestone one instance's journal, step index, children, and awakeables
can each be paged independently through `Keiro.Workflow.Inspection`, with the generation
defaulting to the current one.

Add one statement to each owning schema module. In `keiro/src/Keiro/Workflow/Schema.hs`,
`loadStepIndexPageStmt` selects the six `WorkflowStepRow` columns
`WHERE workflow_id = $1 AND workflow_name = $2 AND generation = $3 AND ($4::text IS NULL OR step_name > $4) ORDER BY step_name LIMIT $5`
(served by the primary key). In `keiro/src/Keiro/Workflow/Child/Schema.hs`,
`lookupChildrenOfParentPageStmt` selects the `ChildRow` columns
`WHERE parent_id = $1 AND parent_name = $2 AND ($3::timestamptz IS NULL OR (created_at, child_id, child_name) > ($3, $4, $5)) ORDER BY created_at, child_id, child_name LIMIT $6`
(the parent index narrows, then the parent's own children sort). In
`keiro/src/Keiro/Workflow/Awakeable/Schema.hs`, `lookupAwakeablesOfOwnerPageStmt` selects the
`AwakeableRow` columns
`WHERE owner_workflow_name = $1 AND owner_workflow_id = $2 AND ($3::timestamptz IS NULL OR (created_at, awakeable_id) > ($3, $4)) ORDER BY created_at, awakeable_id LIMIT $5`
(served by the owner index). Export a thin `Eff`-level function for each, following the
existing `lookupChildrenOfParent` shape, and keep every existing function unchanged.

In `Keiro.Workflow.Inspection` add the four page queries and page types from Interfaces and
Dependencies and their functions `readWorkflowJournalPage`, `loadStepIndexPage`,
`listWorkflowChildrenPage`, and `listWorkflowAwakeablesPage`. Generation resolution is
shared: `Nothing` means `currentGeneration name wid`. The journal page reads
`readStreamForward (workflowGenerationStreamName name wid gen) (StreamVersion from) (pageSize + 1)`
where `from` is `0` without a cursor (kiroku's cursor is exclusive and the first event has
version 1, so `0` reads from the beginning) and the cursor payload is the last returned
event's `streamVersion`. Each recorded event is decoded with
`Keiro.Codec.decodeRecorded workflowJournalCodec`; a decode failure throws
`WorkflowJournalDecodeError` (see the Decision Log). Build `WorkflowJournalEntry` exactly as
`keiro-ops` builds its private `JournalView` today (`stepName`, `recordedAt`, and `payload`
derived from the event: a `StepRecorded` gives its own fields; `WorkflowCompleted` and
`WorkflowCancelled` give the reserved marker name with `null`; `WorkflowFailed` gives the
reason; `WorkflowContinuedAsNew` gives the next generation) and additionally keep the typed
`event`.

Tests to add to the inspection group, each building a real instance rather than seeding rows
by hand where the runtime can produce them:

1. "pages a real journal, step index, children, and awakeables independently": run
   `demoWorkflow` (it journals several steps and completes) for one instance and page its
   journal and its step index with `pageSize = 2`, which is smaller than either total; run
   `parentWorkflow` for a parent, drive its child with `runChildWorkflow`, register a second
   child row for the same parent with `registerChildTx`, and page the children with
   `pageSize = 1`; run `approvalFlowWithId` for an approval instance, register a second
   awakeable row for the same owner with `registerAwakeableTx`, and page the awakeables with
   `pageSize = 1`. For each of the four reads assert that the concatenated pages equal the
   corresponding whole read (`readStreamForward` from version 0 with a large limit,
   `loadStepIndex`, `lookupChildrenOfParent`, and `lookupAwakeable` of each id), that no
   page exceeds its size, and that only the last page lacks a cursor. This is IR-30
   acceptance item 3.
2. "resolves the current generation by default and honors an explicit one": run a workflow
   that calls `continueAsNew`, then read the step page with `generation = Nothing` and assert
   the page's `generation` equals `currentGeneration`; read with `Just 0` and assert the seed
   and rotation marker rows of generation 0.
3. "lists awakeables through the owner index including rows the step index cannot see":
   register an awakeable row for an owner directly with `registerAwakeableTx` (the ADR-6
   crash window where the row exists before the allocation step is journaled) and assert the
   owner page returns it.
4. "raises the runtime's decode error on a corrupt journal event": append a raw event of type
   `StepRecorded` with a non-object payload to a fresh `wf:` stream through
   `Kiroku.Store.Append.appendToStream` and assert `readWorkflowJournalPage` throws
   `WorkflowJournalDecodeError`.

### Milestone 4: Canonical JSON rendering and keiro-ops adoption

At the end of this milestone the library owns the snake_case JSON rendering of every
inspection value, `keiro-ops` renders through it, `wf show` no longer performs an N+1
awakeable lookup, and a test diffs the header read against `wf show --json`.

In `Keiro.Workflow.Inspection` add `instanceToJson`, `childToJson`, `awakeableToJson`,
`stepToJson`, `journalEntryToJson`, and `ToJSON` instances for the five page types. The
object keys are exactly the published `keiro-ops` keys listed in Context and Orientation;
`instanceToJson` adds `status_class` (the vocabulary token) and `stepToJson` renders
`{"step", "result", "recorded_at"}`. A page renders as `{"items": [...], "observed_at": ...}`
plus `"generation"` for journal and step pages and `"next_cursor": "<token>"` only when a
continuation exists — build the key list with `catMaybes` so the key is absent, never
`null`. The awakeable id renders as its UUID text, as today.

In `keiro-ops/src/Keiro/Ops/Workflow.hs`: delete `workflowInstanceJson`, `childJson`,
`awakeableJson`, `journalViewJson`, `JournalView`, `decodeJournalView`, `firstShow`,
`readJournalEvents`, `lookupWorkflowAwakeables`, and `awakeableIds`, replacing each use with
the library function. `runShow` obtains awakeables by draining
`listWorkflowAwakeablesPage` with the maximum page size until no cursor remains, and children
by draining `listWorkflowChildrenPage` the same way, so the JSON `children` and `awakeables`
arrays keep their order and content. `runSteps` drains `loadStepIndexPage` and renders rows
through `stepToJson`; `runJournal` drains `readWorkflowJournalPage` and renders through
`journalEntryToJson`. Keep every `headers`/`rows` table rendering unchanged and keep
`wf list` calling the legacy `listWorkflowInstances`; its element rendering becomes
`instanceToJson`, which adds `status_class` to each element. Add a small private
`drainPages` helper in the ops module.

Add to `keiro-ops/test/Main.hs` under `describe "workflow handlers"`:

1. "renders the instance header identically to the library read": seed an instance with
   `seedStep`, run `Show`, and assert the `instance` member of the JSON equals
   `instanceToJson row` for `Instance.lookupInstance` of the same instance; assert the object
   contains `status_class` with value `"running"`. This is IR-30 acceptance item 2.
2. "shows children and awakeables through the paged reads": register two awakeable rows and
   one child row for the shown instance and assert both arrays are present in creation order
   with the published keys.
3. Existing examples "lists and decodes a real journal without mutating it" and "applies
   exact name/status filters and keyset cursors" continue to pass, which proves the array
   shape of `wf list --json` and the `events` shape of `wf journal --json` are unchanged.

### Milestone 5: Documentation, ADR distillation, and the verification gate

At the end of this milestone a reader of the user documentation knows the status vocabulary,
the cursor contract, the page bounds, and the hand-off to the HTTP layer; the changelogs
describe the change; ADR-28 records the durable boundary; and IR-30 carries implementation
evidence.

Edit `docs/user/durable-workflows.md`: add a section "Inspecting instances" after "The resume
worker" that documents the seven status classes with the exact stored-column rule for each,
the header read (`lookupInstance` plus `statusClassOf`), the five page reads with their
orderings, the `1..500` page bound, the meaning of `next_cursor` absence, the opacity and
kind-binding of cursors ("change any filter and restart without a cursor"), the `observed_at`
clock, and the note that `updated_*` windows are unindexed while creation windows and
creation ordering use `keiro_workflows_created_idx`. Edit `docs/user/operations.md` in the
Durable Workflows section to mention that `wf show` and `wf list` JSON now carry
`status_class` and to point at the vocabulary. Both files are in the profile-governed user
documentation bundle: bump each file's `generated.at`, append a dated entry to
`docs/user/log.md`, and run `just user-documentation-validate`.

Edit `docs/capabilities/durable-execution.md` to add `Keiro.Workflow.Inspection` and
`Keiro.Inspection.Cursor` to `interface`, add an evidence entry naming the new test group,
and append to `docs/capabilities/log.md`; run `just capabilities-validate`.

Edit `docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`:
after the timer paragraph add one paragraph stating that workflow inspection pages belong to
`Keiro.Workflow.Inspection`; that their orderings are immutable keys only (primary key or
creation tuple); that a page is an observation of then-current rows, at most 500 wide, with
a library-minted opaque cursor bound to one read kind and ordering; that the seven-class
status vocabulary is a partition of stored columns; and that operator commands and any
network surface render these values through the library's JSON functions rather than their
own. Advance the ADR's `timestamp`, add the log entry with `okf log add`, and validate.

Add Unreleased entries to `CHANGELOG.md`, `keiro/CHANGELOG.md`, `keiro-ops/CHANGELOG.md`, and
`keiro-migrations/CHANGELOG.md` (New Features for the reads, vocabulary, cursor codec, and
index; Other Changes for the additive `status_class` and `recorded_at` keys and the `wf show`
query reduction). Append an "Implementation evidence" section to
`docs/improvement-requests/complete-workflow-inspection-primitives-for-http.md` that links
this plan, states which acceptance items are satisfied at the library and CLI level (1, 2, 3,
4, and the library half of 5), and states explicitly that endpoint exposure remains IR-26's
work; keep `status: proposed`, advance `timestamp`, and add a dated entry to
`docs/improvement-requests/log.md`.

Finish with the full gate in Concrete Steps and record the results in Progress and Outcomes.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` inside the
Nix development shell. PostgreSQL fixtures are ephemeral; never point a test at a shared
database.

Focused library tests while working on Milestones 1 to 3:

```bash
nix develop -c cabal test keiro-test \
  --test-options='--match "Keiro.Workflow.Inspection"' --test-show-details=direct
```

Expected shape of a passing run (counts grow as milestones land):

```text
Keiro.Workflow.Inspection
  classifies every row the same way in Haskell and SQL [✔]
  pages the ledger completely and stably in key order [✔]
  ...
Finished in 4.2 seconds
12 examples, 0 failures
```

Migration work in Milestone 2:

```bash
nix develop -c cabal run keiro-migrate -- new \
  --manifest keiro-migrations/migrations/manifest \
  --description "add workflow instance creation-order index"
nix develop -c cabal run keiro-migrate -- check keiro-migrations/migrations/manifest
(cd keiro-migrations/migrations && shasum -a 256 0033.sql >> ../migrations.native.lock)
KEIRO_REGENERATE_EXPECTED_SCHEMA=1 nix develop -c cabal test keiro-migrations-test \
  --test-options='--match "checked-in snapshot"'
nix develop -c cabal test keiro-migrations-test --test-show-details=direct
```

The regenerate run prints `regenerated keiro-migrations/expected-schema/native/keiro-v18.txt`;
the full migration suite then reports zero failures with the updated thirty-three counts.
Because `Keiro.Migrations` embeds the directory with Template Haskell, if the new file is not
picked up run `nix develop -c cabal clean` for the package or touch a comment in
`keiro-migrations/src/Keiro/Migrations.hs` as the build gotcha in `Keiro.Workflow`'s module
header describes.

Operator tests in Milestone 4:

```bash
nix develop -c cabal test keiro-ops-test --test-show-details=direct
```

Documentation and bundle validation in Milestone 5:

```bash
dhall --file docs/adr/profile.dhall >/dev/null
okf log add --help
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
nix develop -c just user-documentation-validate
nix develop -c just capabilities-validate
git diff --check
```

The full gate before declaring the plan complete:

```bash
nix fmt
nix develop -c just corpus-regen
nix develop -c just verify
nix flake check
nix develop -c zsh -c 'for package in keiro-core keiro keiro-pgmq keiro-migrations keiro-test-support keiro-dsl keiro-ops; do (cd "$package" && cabal check) || exit; done'
```

`just verify` runs the workspace build, every Haskell suite, the runnable examples, and the
documentation policies; it must exit 0. Plan 270 recorded that concurrent Cabal jobs in one
shared build directory can produce spurious type-identity failures; run the gate serially.

Commits use Conventional Commits and carry both trailers:

```text
ExecPlan: docs/plans/275-add-cursor-paged-workflow-inspection-reads-for-the-http-surface.md
Intention: intention_01m24f03zreg59e5twbm7mpmga
```

Suggested commit boundaries: one per milestone (`feat(workflow): ...` for 1 to 3,
`feat(ops): ...` for 4, `docs: ...` for 5), each leaving the workspace building and the
suites green.


## Validation and Acceptance

IR-30 acceptance item 1 (complete, stable paging by status class): with 23 seeded instances
and `pageSize = 5`, five pages under `ByKey` return every instance exactly once in key order
and only the fifth page lacks `nextCursor`; with 12 instances, three pages under
`ByCreatedDesc` return every instance exactly once in descending creation order and only the
third lacks `nextCursor`; with 20 instances under `ByKey` the fourth page is full and still
lacks `nextCursor`. Filtering by any single class returns only rows whose `statusClassOf` is
that class.

IR-30 acceptance item 2 (header agrees with the CLI): the `keiro-ops` example asserts the
`instance` object of `wf show --json` equals `instanceToJson (lookupInstance ...)` for the
same instance, and that object contains `"status_class": "running"`.

IR-30 acceptance item 3 (independent paging of the four detail reads): the real-instance
example pages journal, steps, children, and awakeables at page sizes smaller than their
totals and proves coverage against the whole reads.

IR-30 acceptance item 4 (a stuck instance is findable through the vocabulary): a claimed then
failed instance is returned by `classes = Just (ClassFailed :| [])` with its lease still
recorded.

IR-30 acceptance item 5 (no ad-hoc SQL): every new statement lives in the schema module that
owns its table, and `keiro-ops` contains no SQL; a reviewer verifies this by reading the diff
of `keiro-ops/src/Keiro/Ops/Workflow.hs`, which only deletes private decoding code.

Performance: the `EXPLAIN` examples prove the creation-order listing and creation windows use
`keiro_workflows_created_idx`, and the step, child, and awakeable pages are bounded by their
owning primary or parent indexes. `wf show` issues one page query per 500 awakeables instead
of one `loadStepIndex` per generation plus one lookup per awakeable. Every page fetches at
most 501 rows. Record the plan text of each `EXPLAIN` in Surprises & Discoveries if it differs
from expectation.

Read-only behavior: the column-comparison example proves no listing changes any instance
row, and the discovery query returns the same set before and after.

Compatibility: the existing `wf list` and `wf journal` examples pass unchanged; the legacy
`listWorkflowInstances` example passes unchanged; no existing exported signature changes.


## Idempotence and Recovery

All reads are repeatable and never write. Tests clone a fresh database per example. The
migration is a `CREATE INDEX IF NOT EXISTS`, so re-applying it is harmless; never edit
`0033.sql` after it ships — a correction is a new migration. If the native snapshot or
lockfile drifts, regenerate the snapshot with the environment variable shown in Concrete
Steps and recompute the checksum line with `shasum -a 256`; review both diffs before
committing. If a `cabal` build fails to see the new migration file, clean the
`keiro-migrations` package build directory as described above.

If `keiro-ops` output must be rolled back, reverting Milestone 4's commit restores the
previous private renderers; the library reads are additive and can stay. If the index must
be dropped in an emergency, `DROP INDEX keiro.keiro_workflows_created_idx` only removes the
`ByCreatedDesc` fast path; the `ByKey` listing and all other reads are unaffected, and the
schema check would report the drift until a forward migration reconciles it.


## Interfaces and Dependencies

New dependency in `keiro/keiro.cabal` library `build-depends`:
`base64-bytestring >=1.2 && <1.3` (already in the install plan at 1.2.1.0). No other
package gains a dependency; no web dependency enters any package.

`keiro/src/Keiro/Inspection/Cursor.hs` (new, exposed):

```haskell
newtype InspectionCursor = InspectionCursor { cursorText :: Text }
  deriving stock (Eq, Show, Generic)

data CursorError
  = MalformedCursor !Text            -- the token is not base64url JSON of the expected shape
  | CursorKindMismatch !Text !Text   -- expected kind, actual kind
  deriving stock (Eq, Show, Generic)

encodeCursor :: (ToJSON payload) => Text -> payload -> InspectionCursor
decodeCursor :: (FromJSON payload) => Text -> InspectionCursor -> Either CursorError payload
```

`keiro/src/Keiro/Workflow/Inspection.hs` (new, exposed):

```haskell
maxInspectionPageSize :: Int              -- 500

data WorkflowStatusClass
  = ClassRunning | ClassRetrying | ClassSleeping | ClassAwaiting
  | ClassCompleted | ClassCancelled | ClassFailed
  deriving stock (Eq, Ord, Show, Bounded, Enum, Generic)

statusClassToText   :: WorkflowStatusClass -> Text
statusClassFromText :: Text -> Maybe WorkflowStatusClass
statusClassOf       :: WorkflowInstanceRow -> WorkflowStatusClass
classStatus         :: WorkflowStatusClass -> WorkflowStatus

data InspectionError
  = InvalidPageSize !Int
  | InvalidCursor !CursorError
  | CursorGenerationMismatch !Int !Int   -- resolved generation, cursor's generation
  deriving stock (Eq, Show, Generic)

data WorkflowListOrdering = ByKey | ByCreatedDesc
  deriving stock (Eq, Show, Generic)

data WorkflowListQuery = WorkflowListQuery
  { classes       :: !(Maybe (NonEmpty WorkflowStatusClass)),
    workflowName  :: !(Maybe Text),
    createdSince  :: !(Maybe UTCTime),   -- inclusive
    createdBefore :: !(Maybe UTCTime),   -- exclusive
    updatedSince  :: !(Maybe UTCTime),   -- inclusive, unindexed
    updatedBefore :: !(Maybe UTCTime),   -- exclusive, unindexed
    ordering      :: !WorkflowListOrdering,
    pageSize      :: !Int,
    cursor        :: !(Maybe InspectionCursor)
  }
  deriving stock (Eq, Show, Generic)

defaultWorkflowListQuery :: WorkflowListQuery   -- no filters, ByKey, pageSize 100, no cursor

data WorkflowListPage = WorkflowListPage
  { items      :: ![WorkflowInstanceRow],
    nextCursor :: !(Maybe InspectionCursor),
    observedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

listWorkflowInstancesPage ::
  (IOE :> es, Store :> es) =>
  WorkflowListQuery -> Eff es (Either InspectionError WorkflowListPage)

data DetailPageQuery = DetailPageQuery
  { generation :: !(Maybe Int),      -- Nothing resolves currentGeneration
    pageSize   :: !Int,
    cursor     :: !(Maybe InspectionCursor)
  }
  deriving stock (Eq, Show, Generic)

data OwnerPageQuery = OwnerPageQuery
  { pageSize :: !Int,
    cursor   :: !(Maybe InspectionCursor)
  }
  deriving stock (Eq, Show, Generic)

data WorkflowJournalEntry = WorkflowJournalEntry
  { eventId        :: !UUID,
    eventType      :: !Text,
    streamVersion  :: !Int64,
    globalPosition :: !Int64,
    stepName       :: !Text,
    recordedAt     :: !UTCTime,
    payload        :: !Value,
    event          :: !WorkflowJournalEvent
  }
  deriving stock (Eq, Show, Generic)

data WorkflowJournalPage = WorkflowJournalPage
  { generation :: !Int, items :: ![WorkflowJournalEntry],
    nextCursor :: !(Maybe InspectionCursor), observedAt :: !UTCTime }
data WorkflowStepPage = WorkflowStepPage
  { generation :: !Int, items :: ![WorkflowStepRow],
    nextCursor :: !(Maybe InspectionCursor), observedAt :: !UTCTime }
data WorkflowChildPage = WorkflowChildPage
  { items :: ![ChildRow], nextCursor :: !(Maybe InspectionCursor), observedAt :: !UTCTime }
data WorkflowAwakeablePage = WorkflowAwakeablePage
  { items :: ![AwakeableRow], nextCursor :: !(Maybe InspectionCursor), observedAt :: !UTCTime }

readWorkflowJournalPage ::
  (IOE :> es, Store :> es) =>
  WorkflowName -> WorkflowId -> DetailPageQuery ->
  Eff es (Either InspectionError WorkflowJournalPage)   -- throws WorkflowJournalDecodeError on corruption
loadStepIndexPage ::
  (IOE :> es, Store :> es) =>
  WorkflowName -> WorkflowId -> DetailPageQuery -> Eff es (Either InspectionError WorkflowStepPage)
listWorkflowChildrenPage ::
  (IOE :> es, Store :> es) =>
  WorkflowName -> WorkflowId -> OwnerPageQuery -> Eff es (Either InspectionError WorkflowChildPage)
listWorkflowAwakeablesPage ::
  (IOE :> es, Store :> es) =>
  WorkflowName -> WorkflowId -> OwnerPageQuery -> Eff es (Either InspectionError WorkflowAwakeablePage)

-- Canonical wire rendering (snake_case; the keys keiro-ops already publishes).
instanceToJson     :: WorkflowInstanceRow -> Value   -- adds "status_class"
childToJson        :: ChildRow -> Value
awakeableToJson    :: AwakeableRow -> Value
stepToJson         :: WorkflowStepRow -> Value       -- {"step","result","recorded_at"}
journalEntryToJson :: WorkflowJournalEntry -> Value
instance ToJSON WorkflowListPage      -- {"items","observed_at"[,"next_cursor"]}
instance ToJSON WorkflowJournalPage   -- adds "generation"
instance ToJSON WorkflowStepPage      -- adds "generation"
instance ToJSON WorkflowChildPage
instance ToJSON WorkflowAwakeablePage
```

The cursor payloads and kind tags, which the HTTP layer never needs to know but a debugger
will: `wf-key` carries `[workflow_name, workflow_id]`; `wf-created` carries
`[created_at, workflow_name, workflow_id]`; `wf-steps` carries `[generation, step_name]`;
`wf-journal` carries `[generation, stream_version]`; `wf-children` carries
`[created_at, child_id, child_name]`; `wf-awakeables` carries `[created_at, awakeable_id]`.
The generation inside a journal or step cursor must equal the page's resolved generation,
otherwise `CursorGenerationMismatch resolved cursorGeneration` is returned, so a
`continueAsNew` rotation between two page requests cannot silently splice two journals; the
client restarts on the generation it wants, passing it explicitly.

Schema-module additions (all `Eff`-level, read-only, mirroring the existing lookups):
`Keiro.Workflow.Schema.loadStepIndexPage :: (Store :> es) => WorkflowName -> WorkflowId -> Int -> Maybe Text -> Int -> Eff es [WorkflowStepRow]`,
`Keiro.Workflow.Child.Schema.lookupChildrenOfParentPage :: (Store :> es) => Text -> Text -> Maybe (UTCTime, Text, Text) -> Int -> Eff es [ChildRow]`,
`Keiro.Workflow.Awakeable.Schema.lookupAwakeablesOfOwnerPage :: (Store :> es) => Text -> Text -> Maybe (UTCTime, UUID) -> Int -> Eff es [AwakeableRow]`,
and in `Keiro.Workflow.Instance` the two ordering statements behind a private
`listInstancesBy` that `listWorkflowInstances` (unchanged signature) and
`listWorkflowInstancesPage` both call. All existing exports of these modules keep their
signatures and behavior.

Hand-off contract for the IR-26 plan (not implemented here): each read maps to one GET route
whose query parameters are the query record's fields in snake_case (`status_class`
repeatable, `workflow_name`, `created_since`, `created_before`, `updated_since`,
`updated_before`, `ordering` in `key` or `created_desc`, `limit`, `from`), whose body is the
page's `ToJSON` rendering verbatim, and whose `InvalidPageSize` and `InvalidCursor` results
become the conventions' error envelope with codes `invalid_page_size` and `invalid_cursor`.

Dependency sources consulted through Mori: kiroku-store at
`mori://shinzui/kiroku/packages/kiroku-store` (`Kiroku.Store.Read.readStreamForward` takes an
exclusive `StreamVersion` cursor and an `Int32` limit; `StreamVersion` is one-indexed with
`0` meaning "from the first event"; `RecordedEvent` carries `eventId`, `eventType`,
`streamVersion`, and `globalPosition`).
