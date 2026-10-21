---
id: 275
slug: add-cursor-paged-workflow-inspection-reads-for-the-http-surface
title: "Add cursor-paged workflow inspection reads for the HTTP surface"
kind: exec-plan
created_at: 2026-09-10T01:38:10Z
intention: "intention_01m24f03zreg59e5twbm7mpmga"
master_plan: "docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md"
provenance:
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-30T23:42:28Z
      mode: "update"
      note: "Adopted by MasterPlan 45: cursor kind registry, cursorReader placement, instanceToJson hand-off to plan 277, migration number allocation"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T01:38:52Z
      mode: "update"
      note: "Correct hot-path isolation, bounded inspection/feed ownership, released APIs, observation semantics, and mandatory performance acceptance; implementation remains pending."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-20T17:15:00Z
      mode: "implement"
      note: "Begin independent workflow inspection work while EP-1 awaits the integrated performance gate"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T01:22:22Z
      verdict: "changes-requested"
      note: "Pre-update review: paged library reads have no CLI routes; forced-index proofs do not bound filtered scans; host clocks and generation cursors need correction."
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

Current boundary (2026-10-20, user-directed core-path priority): saturation
comparisons found a 9.22% median ordinary-writer capacity loss with the
inspection-only stored class/indexes. The 100/s paced matrix had concealed that
loss of headroom. Withdraw unpublished migrations 0033/0034, retaining the exact
0.21 writer schema and migration payloads. Inspection class predicates use
stored runtime fields and existing indexes; no new column/index is maintained
by writes. Historical index decisions and query plans below describe rejected
prototypes, not the final implementation. Fresh read and capacity evidence is
required before completion.


2026-10-20: The bounded exact-header candidate passes the complete Nix
`just verify`: 772 Keiro examples, 51 ops, 29 HTTP, 43 migration, 25 example
application examples, coarse retention and the DSL/policy/documentation gates.
Infinity values agree with the ordinary binary decoder. Required measured
interference, strict retention and final release checks remain open.


- [x] (2026-10-13) Correctness and hot-path design review applied; implementation remains outstanding.
- [ ] Validate the review constraints and record the required performance/correctness evidence before marking this plan complete.


- [x] (2026-10-20) Milestone 1: opaque cursor codec, status-class vocabulary, and the bounded instance
      listing over `keiro_workflows` in key order and creation order, with the legacy
      `listWorkflowInstances` SQL unchanged. Eleven focused examples cover classes, both orders, UTC cursors, validation, and read-only behavior.
- [ ] Milestone 2: preserve the ordinary writer schema and capacity. Classify
      during reads using existing status/key indexes; retain bounded large-key
      work and deadline-bound scan/sort paths. Validate actual prepared plans and
      matched writer capacity. The unpublished 0033/0034 prototypes are withdrawn.
- [x] (2026-10-20) Milestone 3: paged detail reads (journal, step index, children, awakeables) with
      generation resolution, exercised against a real workflow instance.
- [x] (2026-10-20) Milestone 4: canonical JSON rendering in the library and `keiro-ops` adoption
      (`wf show`, `wf steps`, `wf journal`), including header agreement, six parsed routes, HTTP pagination and typed failures, and pure pre-admission validation; 51 ops and 22 HTTP examples pass.
- [ ] Milestone 5: documentation, changelogs, ADR-28 update, IR-30 evidence, and the full
      verification gate.


## Surprises & Discoveries

2026-10-20: The conditional reader now also preserves infinity timestamp
behavior from the released binary decoder. Its ordinary decoder treats the
Int64 wire sentinels as microseconds from 2000; SQL date subtraction on infinity
would instead fail. Explicit image markers reconstruct the same UTCTime, and
all six timestamp fields are covered against the ordinary lookup. The 16
focused examples and 29 HTTP examples pass after this correction.


2026-10-20: HTTP allocation attribution motivates an owning-session header
read and a prototype conditional image read. The latter compares all thirteen
current fields in one SELECT, rather than trusting a hash or transaction id.
Every individual field mutation, row absence and raw/escaped image limits have
regressions. A far-future microsecond parity case rejects a single numeric-epoch
representation: split UTC day/seconds avoids its rounding, while BC dates avoid
textual JSON date parsing. The bounded HTTP presentation candidate now uses this exact owning query;
its 16 focused query examples and 29 HTTP examples pass. Allocation and matched
interference checks remain pending.
The diagnostic alone is not performance acceptance.

2026-10-20: The final guarded candidate passes the complete Nix `just verify`
with the registered Mori connection supplied, plus strict IR profile validation.
The verification demo uses a unique database and removes it afterward; the
existing interactive demo with an earlier unreleased checksum is untouched.
This is correctness/coarse-retention evidence, not strict cohort acceptance.

2026-10-20: Longer guarded-schema diagnostics retain five 1,000-operation pairs
per profile. Normal completed-workflow medians: p95 +0.25%, allocation +0.15%,
WAL +8.86%; the p95 range -9.01%..+21.83% remains inconclusive. A storage-only
large-row failure/lease profile has p95 +1.03% and WAL +43.75%, with 2000/3000
HOT versus 2989..3000 baseline. Repeated crash/reset has p95 +1.42% and 950/1050
HOT versus 1050/1050; only class transitions lose HOT. Cluster WAL/CPU vary
substantially, all raw legs remain, and none is a pre-change full-cohort pass.
A proposed completed-workflow profile with a 2700-character id aborts before
measurement at the journal stream-name contract; its failure is retained.
Large wake-ledger row compatibility is distinct from executable workflow input.

2026-10-20: Key-domain evidence in `key-domain/` rejects the unguarded creation,
class and owner compound indexes. PostgreSQL accepts a 2684-byte workflow name
or 2687-byte workflow id through the old primary key but rejects the larger
inspection index tuples. A per-class name/id index still rejects the latter;
reversing text fields changes alignment. Child and awakeable candidate indexes
also reject existing valid keys. Ordinary writer compatibility is required,
not inferred from fast read plans.

2026-10-20: The revised, unreleased migrations 0033/0034 guard wide workflow
index entries. A fixed-width class/name-hash/id-hash index locates exceptional
keys, with exact text rechecks. One read statement budgets the raw class/name
population before cursor/time filtering (64 candidates / 256 KiB key bytes),
merges it with the narrow ordered page, and returns InspectionWorkLimitExceeded
rather than silently omitting rows if the budget is exceeded. Ops uses
inspection_result_too_large / HTTP 413. Existing large writer keys remain
valid; both list orderings include a bounded exceptional set. The 0033 checksum changes before first publication. An earlier full verification
had applied its prior payload to the local interactive jitsurei database, so the
next default verification correctly refused that checksum. The database is
preserved. `just verify` now runs demos in a uniquely named disposable database,
with cleanup, rather than mutating/relying on the interactive demo's history.
The historical shipped migration lock is unchanged; no ledger repair is used.

2026-10-20: All 13 focused workflow examples pass, including large-key traversal,
raw exceptional-population limits before deep cursor filtering and byte limits.
The revised migration/ops/HTTP suites pass 43/51/26 examples. The last full
767-example Keiro gate predates this revision; final full verification remains
open. The preliminary added-owner-index writer median p95 is +6.72% and WAL
+8.51%, so those indexes are unselected. Child/awakeable pages remain manual
with host SQL/read deadlines, outside automatic feeds. Their row limit is a
cardinality cap, not a bounded scan claim.

2026-10-20: Migration 0034 is allocated through `keiro-migrate new` and adds
`inspection_status_class` as a stored generated column plus a class/name/id
index. Actual supported-API evidence in `query-stored-class/` has 60 normal
prepared plans. At 100,000 rows generic default first/deep pages examine 22,
rare failed 21, absent retrying/name zero; small-name examines 31. The fixed
seven branches share a bound mask, preserving one shape across class sets.
Update windows still examine 100,000 and creation-order rare status 20,001;
these manual shapes are excluded from automatic feed inputs and use host
statement/deadline policy. This is access-path evidence, not the full 5% gate.

2026-10-20: The stored projection avoids the direct expression index's repeated
retry HOT loss. Its short normal write legs have 600/800 HOT versus 597/800
baseline and WAL about +5.55%; paired p95 varies -14.0% to +9.35%, so no latency
pass is claimed. Crash diagnostics retain HOT except class transitions.
The migration rewrites the table and requires a write-blocking maintenance
window. No Haskell writer statement, event read or metadata encoding is added.

2026-10-20: Generated CASE expressions are multiline in pg_get_expr. The native
fingerprint now JSON-quotes generated expressions into one snapshot line and
records stored/virtual derivation. Migration tests verify existing-row backfill,
subsequent class transitions and drift when derivation is removed. All 767
Keiro, 43 migration, 51 ops and 25 HTTP examples pass after correcting remaining
upgrade-count assertions. This is the affected-suite gate; the last full
`just verify` predates this candidate.

2026-10-20: Stored PostgreSQL keys can exceed the decoder's cursor limit.
All page producers now use `encodeCursorBounded` and return
`CursorResultTooLarge` rather than a next token over 4096 bytes. Ops preserves
`inspection_result_too_large`; HTTP returns 413. Eleven focused workflow,
51 ops and 25 HTTP examples pass, including long multibyte stored names.

2026-10-20: `class-branch-prototype/` retains a fixed seven-class UNION shape
with one bound mask: generic first pages inspect 22 rows for all classes,
21 for running, 21 for rare failed at 100,000 rows, and zero for absent
retrying. It is not the actual API query and proves no write acceptance.
`class-index-write-nominal/` has unchanged HOT counts and WAL about +5.35%,
but `class-index-write-crash/` rejects the expression index: all 210 baseline
updates are HOT versus zero candidate, with about +190% WAL in each of five
pairs. A stored generated class is being evaluated on clones; no additional
migration is selected. These are short storage diagnostics, not the matched
5% cohort gate.

2026-10-20: The temporary key/class-index experiment under
`keiro/bench/results/inspection/query-key-and-class-experiment/` proves a key
index fixes unfiltered/name-filtered first/deep pages (21 examined rows), but
indexes alone do not fix generic array-valued class predicates. At 100,000 rows
custom absent-class scans zero through the class index; generic absent-class
scans all 100,000 rows and generic rare failed status scans 21,000. An absent
update window still scans the whole ledger. No additional migration is selected
from this experiment. Query-shape and write/HOT-cost acceptance remains open.

2026-10-20: Five short alternating same-binary creation-index write legs retain
raw queue/schedule/claim/resume samples and PostgreSQL WAL/HOT counters in
`keiro/bench/results/inspection/creation-index-write/`. The index adds about
3.7% WAL per operation; measured HOT counts are unchanged. Paired p95 changes
range from -12.0% to +7.4%, so latency acceptance is inconclusive. Longer
matched runs, allocations, pre-change binary and active-inspection comparisons
remain required. This is preliminary evidence, not completion of M2.

2026-10-20: Full Nix `just verify` passed after the page/CLI/migration changes,
including 766 Keiro examples, all DSL conformance and mutation proofs, and 41
migration examples. The affected HTTP suite subsequently passed 24 examples
with delivery admission and connection churn. M2's query/write-cost evidence
and the matched performance gates remain open; functional verification alone
does not complete this child.

2026-10-20: Actual prepared-query evidence at 10,000/100,000 rows, both
`force_custom_plan` and `force_generic_plan`, shows that the proposed creation
index alone is insufficient. The physical primary key is
`(workflow_id, workflow_name)`, opposite the inspection key ordering. At
100,000 rows the generic default key page and rare-status page examine the
whole ledger; creation first/deep pages scan 21 rows. The retained
[probe and plans](../../keiro/bench/results/inspection/query-before-key-index/README.md)
are rejection evidence, not a passing performance gate. Matching ordered and
filtered access plus write/WAL experiments remain implementation work.

Pure validation is exported by the owning library and delegated through
`Keiro.Ops.validateCommand`, so invalid page sizes, malformed/foreign cursors,
and invalid generations are refused by HTTP before admission/schema scans.
Detail read cursors bind the owner as well as kind and generation. The header
HTTP test seeds 100,000 children and counts exactly two inspection pool uses:
one verification session and one instance read.


2026-10-13 source review: Library-only pages never become routes through the parser. Forced index use and owner-only indexes do not establish bounded filtering/sorting, and host time is not the database observation clock.


(None yet.)


## Decision Log

- Decision (2026-10-20): preserve the ordinary writer key domain by guarding
  large ordered workflow index entries and budgeting a separately indexed
  exceptional set in the same statement. Reject unguarded larger tuples and
  reversed text indexes that narrow valid keys. Preserve database text ordering
  and cursor contents; hashes only locate/reorder bounded candidates.
- Decision (2026-10-20): keep owner detail shapes manual under explicit host
  deadlines after their compound-index write and key-domain failures. Do not
  introduce them into automatic feeds or claim cardinality bounds are scan bounds.

- Decision (2026-10-20): use a stored generated class and fixed literal class
  branches for key-order inspection. Reject indexing the raw attempt expression,
  which destroys HOT on every retry increment. Generated storage preserves
  derivation without changing ordinary writer SQL; it has measured WAL and
  maintenance costs, and does not waive the full interference gate.
- Decision (2026-10-20): retain broad manual time/status shapes with explicit
  host deadlines; automatic workflow views use only key/class/name inputs.

- Decision (2026-10-20): retain the initial creation-index migration and the
  complete failed query-cost evidence as an implementation checkpoint. Default
  key and rare-status reads cannot be accepted for automatic refresh until
  matching access paths and write/WAL measurements pass. Do not mark this child
  complete based only on correct page results or the creation-order proof.
- Decision (2026-10-20): export pure owning-library validation and delegate it
  through the command boundary so HTTP refuses malformed cursors/page sizes
  before catalog scans. Direct library reads validate again.


- Decision (2026-10-13): apply the current review constraints in Context, Plan of Work, and Validation. Rationale: Library-only pages never become routes through the parser. Forced index use and owner-only indexes do not establish bounded filtering/sorting, and host time is not the database observation clock. Historical September decisions below are retained as history; conflicting create-first, downgrade, zero-cost-index, unconditional-provenance and partial-completion instructions are withdrawn.


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

- Decision: This plan is adopted as EP-2 of
  [MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md),
  which coordinates the keiro-ui inspection cohort (plans 274, 275, 276, 277, 278, 302, and
  303). The MasterPlan's Integration Points are authoritative for every artifact this plan
  shares with a sibling; where this plan's older text disagrees, the entries below and the
  Coordination subsection in Context and Orientation state the settled form.
  Rationale: the five request plans were written the same day by parallel sessions and
  disagree on the cursor codec, the migration number, and the workflow rendering; MasterPlan
  45 settles those once so no implementer has to reconcile five plans.
  Date: 2026-09-30

- Decision: `keiro/src/Keiro/Inspection/Cursor.hs` is the only cursor codec for every keiro
  inspection read, and this plan owns it together with the kind-tag registry: `wf-key`,
  `wf-created`, `wf-steps`, `wf-journal`, `wf-children`, `wf-awakeables` (this plan),
  `aggregate-list` (plan 278, EP-3), `timer-pending` and `pm-list` (plan 274, EP-4).
  Whichever of plans 274, 275, 277, or 278 lands first creates the module to the exact
  interface in Interfaces and Dependencies and adds `base64-bytestring >=1.2 && <1.3` to
  `keiro/keiro.cabal`; the others import it. Plan 277's proposed `Keiro.Ops.Cursor` in
  `keiro-ops` and plan 274's proposed textual timer cursor are withdrawn.
  Rationale: MasterPlan 45 settles one codec so every read mints interchangeable tokens and
  the CLI and the HTTP layer carry them unchanged; a create-first rule keeps wave-one plans
  independent without blocking any of them on this one.
  Date: 2026-09-30

- Decision: The one `optparse-applicative` reader that turns a `--after CURSOR` option into
  an `InspectionCursor`, `cursorReader :: ReadM InspectionCursor`, lives in
  `keiro-ops/src/Keiro/Ops/Parse.hs` and is created by whichever plan first needs it. It only
  wraps the option text; the library read validates the kind and reports `InvalidCursor`.
  Rationale: MasterPlan 45 places all option parsing helpers in `Keiro.Ops.Parse` beside
  `positiveIntReader`, and keeping kind validation in the library means the CLI and the HTTP
  layer (which passes the query value through as the same option) fail identically.
  Date: 2026-09-30

- Decision: Plan 277 (EP-5, the live feeds) renders its `workflows` feed items with this
  plan's `instanceToJson` so that feed items equal `wf list` items. If plan 277 lands first,
  it exports the existing private `workflowInstanceJson` from `Keiro.Ops.Workflow`
  temporarily, and this plan's Milestone 4 replaces that import with `instanceToJson` when it
  deletes `workflowInstanceJson`.
  Rationale: ADR-40's fourth condition requires a feed's items to be identical to the paired
  read's rendering; one library-owned encoder is the only way that holds by construction.
  Date: 2026-09-30

- Decision: The migration this plan adds is "the next migration"; the number `0033` named
  in the 2026-09-10 decision above was the next free number on that day and is not a
  reservation. `cabal run keiro-migrate -- new` allocates the real number at implementation,
  and plan 274 (a possible pending-timer index) and plan 299 (the outbox claim-generation
  fence) also add migrations, so the manifest line, the lock line, the expected-schema
  snapshot, and the hard-coded counts in `keiro-migrations/test/Main.hs` are rebased on
  whatever exists when Milestone 2 runs.
  Rationale: MasterPlan 45 found three plans claiming `0033`; the tool exists to allocate.
  Date: 2026-09-30


## Outcomes & Retrospective

2026-10-20 guarded-index checkpoint: focused workflow/ops/HTTP/migration
checks pass 13/51/26/43 examples. Actual custom/generic plans now bound the
normal key/class/name paths and exceptional-key candidate work. The earlier
access-path rejection below is superseded by guarded migrations 0033/0034 and
an explicit wide-key budget; historical evidence is retained. Five paired
schema-only write runs per profile are diagnostic, with noisy latency and
higher wide-row WAL. The final-candidate Nix `just verify` passes: 769 Keiro examples, all DSL
proofs, coarse retention, repository policies, strict documentation/terminology
and 43 migration examples. Full pre-change interference and strict retention
acceptance remain open. This child stays
In Progress and its dependents remain unstarted.

2026-10-20 functional checkpoint: the library, six bounded CLI commands,
canonical rendering, typed failures, and HTTP traversal are implemented.
Focused workflow/ops/HTTP suites pass 10/51/22 examples; the migration suite
passes 41 examples, including migration 0033 and its one-line schema snapshot
change. Query-cost acceptance fails for the default key and rare-status shapes
on the 100,000-row fixture. This child remains In Progress. No write-cost,
interference, retention, whole-repository final-candidate, or release acceptance
is claimed. Resolve the measured access-path failure before dependent plans
can start under the whole-child prerequisites.


2026-10-13: Design corrected after source review; no feature implementation or passing performance evidence exists yet. The new acceptance gates must be met during implementation.


(To be filled during and after implementation.)


## Context and Orientation

### Review baseline and implementation boundary (2026-10-13)

This plan was reviewed against Keiro commit `cbcc593df2445780e2c42406c6b633ae530fb8ea`. Keiro is now 0.20.0.0 and already depends on released `kiroku-store ^>=0.11.0.0`; historical September version statements and Decision Log entries below are historical evidence, not instructions to downgrade. Hackage source and upstream tag `kiroku-store-v0.11.0.0` confirm the four-argument, `BrowsePageSize`-bounded listing API. Recheck the registry and upstream tags before changing bounds. [ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md) now also requires bounded inspection work and measured hot-path isolation.

Shared implementation has one owner: plan 275 creates the cursor codec, plan 278 creates source-reporting hydration, plan 274 creates pending-timer reads, and plan 276 creates the transport and admission budget. Consumers wait for those artifacts; they do not implement an absent owner's module. The old create-first instructions are withdrawn. The hard prerequisites for this plan are none.

Application constructors allocate resources once in IO and return a bare WAI application: `opsApplication` and `opsApplicationWithFeeds` now return `IO Application`. Bind their results once during startup, never construct a new admission budget for each request. Pure composition still takes ordinary `Application` values. Per-request schema verification, handler execution, and feed refreshes share a bounded inspection budget; they must never use the writer's reserved pool capacity by default.


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

### Coordination under MasterPlan 45 (2026-09-30)

This plan is coordinated by [MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md). Hard prerequisites: none. The 2026-10-13 Integration Points are the current contracts; older dated Decision Log and Revision notes preserve history, not alternative implementation instructions.

Plan 275 creates `Keiro.Inspection.Cursor` and `Keiro.Ops.Parse.cursorReader`; 278 creates source-reporting hydration; 274 creates the pending-timer read and encoder; 276 creates the shared inspection budget and HTTP application; 277 consumes these and owns bounded feeds; 302 composes allocated applications; 303 requires all work and measured interference gates before closure. Consumers import these interfaces after their prerequisites, never create competing implementations. Every child preserves existing hooks while extending them.

Keiro's current tree is 0.20.0.0 with `kiroku-store ^>=0.11.0.0`; released `listStreams` takes category, prefix, cursor and `BrowsePageSize`. The compatible released metrics surface is 0.3.0.0. Verify the registry and upstream tags again at implementation, retain supported current bounds, and do not defer listings on the obsolete 0.10 release gate. Allocate migration numbers and OKF handles at implementation. Strict ADR-40 and ADR-28 boundaries apply.

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
Milestone 2. The legacy `listWorkflowInstances` keeps its exact signature and existing SQL; new inspection filters must not add CASE evaluation or wider planning work to existing callers.

Create `keiro/src/Keiro/Inspection/Cursor.hs` (add it to `exposed-modules` in
`keiro/keiro.cabal`, and add `base64-bytestring >=1.2 && <1.3` to the library
`build-depends`). It defines `InspectionCursor` (a newtype over `Text` whose constructor is
exported so the HTTP layer and CLI can carry it, but whose contents are documented as opaque),
`CursorError`, `maxCursorBytes`, `encodeCursor`, `encodeCursorBounded`, and `decodeCursor`. Encoding builds the compact JSON object
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
(`wf-key` or `wf-created`), reads the database clock for `observedAt` in the row statement (including an empty-page result), runs the statement for
the requested ordering with `LIMIT pageSize + 1`, and returns the first `pageSize` rows plus
a cursor minted from the last returned row's key only when the extra row was present.

In `keiro/src/Keiro/Workflow/Instance.hs`, retain `listWorkflowInstancesStmt` and add two inspection-only
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
proves they agree on every fixture row. Keep the legacy `listWorkflowInstances` signature, record and SQL unchanged. Inspection windows are half-open: `since` inclusive and `before` exclusive. Share row decoding, not a more complex optional-filter statement with runtime callers.

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

The implemented design uses [0033.sql](../../keiro-migrations/migrations/0033.sql)
and [0034.sql](../../keiro-migrations/migrations/0034.sql). Both ordered text
indexes exclude keys whose combined raw length exceeds 2600 bytes. Migration
0034 adds the stored inspection class and its normal-key index plus a fixed-width
class/name-hash/id-hash index for exceptional candidates. Reads recheck full
text, budget the raw exceptional population before cursor/time predicates, and
merge at most 64 candidates / 256 KiB. This supersedes the original unguarded
single-index proposal: it rejected keys the old primary key accepted. The
stored-column migration rewrites the table and requires a maintenance window.
Do not recreate or renumber these already allocated migrations; the allocation
commands below describe their original creation workflow.

A row limit bounds response cardinality, not query work. Keep reproducible fixtures and EXPLAIN transcripts outside the fast unit suite. Seed 10,000 and 100,000 rows with skew (one owner has 90% of rows, rare/absent filters, and many equal timestamps), ANALYZE, and measure first and deep pages with `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)` using the actual parameterized query under both `force_custom_plan` and `force_generic_plan`. Run with normal planner settings; `enable_seqscan = off` is a diagnostic only, never acceptance. Record rows examined, rows removed by filter, sort memory/spill, buffers, planning/execution time and query count. Separate absent/present-filter statement shapes where nullable-OR predicates defeat ordered index access. A repeatable dashboard query that scans or sorts the whole ledger at each refresh is not accepted merely because it returns 501 rows. Either provide an evidence-backed matching index, bound the supported filter workload and deadline explicitly, or keep that shape out of automatic feeds. Measure schedule/claim/resume throughput, WAL and HOT-update behavior before and after every index. An immutable index key does not guarantee that index maintenance costs zero on non-HOT updates.

The proposed creation index supports unfiltered creation order but does not prove bounded cost for rare status/name/update-window filters or key-order sorting. Inspect those shapes separately. For child and awakeable pages, owner-only indexes still sort all of one owner's rows; measure owners with 100,000 children/awakeables and evaluate `(parent_id,parent_name,created_at,child_id,child_name)` and `(owner_workflow_name,owner_workflow_id,created_at,awakeable_id)` indexes. Add only indexes justified by the read/write experiment, allocated through normal migrations. Do not claim one index serves every order or that a creation index is never maintained on updates.


At the end of this milestone the creation ordering and creation windows from Milestone 1 are
served by an index, proven by `EXPLAIN`, and the migration suite, lockfile, and native
schema snapshot include the new migration. The migration's number is not fixed by this plan:
`0033` was the next free number on 2026-09-10, but plan 274 (a possible pending-timer index)
and plan 299 (the outbox claim-generation fence) also add migrations, so the number is
whatever `keiro-migrate new` allocates when this milestone runs. Below, `<NNNN>` stands for
that zero-padded number, and every count, title, and lock line is rebased on the manifest as
it exists at that moment.

Create the migration through the standard tool so the manifest is appended consistently:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
nix develop -c cabal run keiro-migrate -- new \
  --manifest keiro-migrations/migrations/manifest \
  --description "add workflow instance creation-order index"
```

The tool prints the file it created, `keiro-migrations/migrations/<NNNN>.sql`, with the
description as its first comment line, and appends `<NNNN>.sql` to
`keiro-migrations/migrations/manifest`. Record the printed number in Progress. Replace the
body with:

```sql
-- add workflow instance creation-order index
-- Creation-order listing and creation windows for workflow inspection reads.
-- created_at is immutable, so a keyset over (created_at, workflow_name,
-- workflow_id) never skips or repeats under concurrent status or lease updates,
-- and a backward scan of this index serves the newest-first ordering.
-- This index does not establish bounded key-order or filtered reads.
CREATE INDEX IF NOT EXISTS keiro_workflows_created_idx
  ON keiro.keiro_workflows (created_at, workflow_name, workflow_id)
  WHERE octet_length(workflow_name) + octet_length(workflow_id) <= 2600;
```

Append the checksum line and regenerate the snapshot:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations/migrations
shasum -a 256 <NNNN>.sql >> ../migrations.native.lock
cd /Users/shinzui/Keikaku/bokuno/keiro
KEIRO_REGENERATE_EXPECTED_SCHEMA=1 nix develop -c cabal test keiro-migrations-test \
  --test-options='--match "checked-in snapshot"'
git diff --stat keiro-migrations/expected-schema/native/keiro-v18.txt
```

The `keiro-migrate new` command (from `mori://shinzui/pg-migrate`) names the file with the
next zero-padded number, seeds it with the description as a comment line, and appends it to
the manifest. The lockfile format is `<sha256><two spaces><file name>`, which is what
`shasum -a 256` prints when run inside the directory. The creation migration adds one index line for
`keiro_workflows_created_idx`, including its width guard. The class migration
also adds its generated-column expression and two guarded indexes; review
those lines together with the native lock and manifest. In `keiro-migrations/test/Main.hs`
increment the migration count the tests hard-code by one, in the three test titles that
state it in words and digits and in `nativeMigrationFiles` (append `"<NNNN>.sql"` after the
last entry), and add an example under `describe "fresh native databases"` named
"<NNNN> adds the creation-order index" that applies the plan to a fresh database, asserts
`SELECT indexdef FROM pg_indexes WHERE indexname = 'keiro_workflows_created_idx'` returns
the guarded definition checked by the current migration test,
and inserts and reads back one instance row to show the table is unaffected. Add an
Unreleased entry to `keiro-migrations/CHANGELOG.md` in the style of the 0.16.0.0 entry for
0032, naming the allocated number.

Verify the index exists and preserves row semantics in the migration test. The normal-planner, actual-parameterized-query experiments above supply the performance evidence; do not assert that key-order queries must name the creation-order index or use forced index selection as acceptance.

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
`listWorkflowChildrenPage`, and `listWorkflowAwakeablesPage`. Generation resolution is shared: on the first page, `Nothing` means `currentGeneration name wid`; decode and validate subsequent cursor generation and owner before reading. If an implicit current generation changed, return `CursorGenerationMismatch` and let the client retry with an explicit generation. Journal cursors carry `[workflow_name, workflow_id, generation, stream_version]`; step cursors carry `[workflow_name, workflow_id, generation, step_name]`. Match the owner as well as the kind and reject nonpositive/out-of-range payloads before SQL. The journal page reads
`readStreamForward (workflowGenerationStreamName name wid gen) (StreamVersion from) (pageSize + 1)`
where `from` is `0` without a cursor (kiroku's cursor is exclusive and the first event has
version 1, so `0` reads from the beginning) and the cursor payload includes owner, resolved generation and the last returned
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

Add read-only `wf inspect list`, `wf inspect header NAME ID`, `wf inspect journal NAME ID`, `wf inspect steps NAME ID`, `wf inspect children NAME ID`, and `wf inspect awakeables NAME ID`. These call exactly one new library page (header does only `lookupInstance`) and return its JSON unchanged. List flags are repeatable `--status-class`, `--workflow-name`, half-open `--created-since/--created-before` and `--updated-since/--updated-before`, `--ordering key|created_desc`, `--limit` and `--after`; journal/steps also take `--generation`. Use `cursorReader`, validate before SQL, and cover all six commands through the parser, `isMutation`, and handler tests. EP-1 then serves `/wf/inspect/...` mechanically, using these same option names in snake_case. Legacy `wf list/show/steps/journal` remain compatible and may be expensive; a browser uses the bounded subtree. Typed page failures require `InspectionFailed !Text !Text` in `OpsOutcome` (stable code and message; owned by EP-2, with updates to CLI rendering and all matches) so EP-1 maps `invalid_page_size`, `invalid_cursor`, and `cursor_generation_mismatch` without parsing error text. Page producers use the checked encoder and return
`CursorResultTooLarge` when a stored continuation cannot fit the 4096-byte token
limit; ops carries `inspection_result_too_large`, mapped to HTTP 413. Never
truncate a continuation key. Existing `Failed Text` remains supported. If EP-1 already exists, this milestone updates its outcome match and HTTP tests; otherwise EP-1 consumes the variant when it lands. The variant introduces no HTTP dependency in `keiro-ops`.

Header/page rendering equality tests compare values from one injected/captured library result. Independent calls with different `observed_at` timestamps cannot be byte-equal. Integration tests compare stable fields and separately assert clock/age relations. Do not discard real state differences to force equality.


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
(cd keiro-migrations/migrations && shasum -a 256 <NNNN>.sql >> ../migrations.native.lock)
KEIRO_REGENERATE_EXPECTED_SCHEMA=1 nix develop -c cabal test keiro-migrations-test \
  --test-options='--match "checked-in snapshot"'
nix develop -c cabal test keiro-migrations-test --test-show-details=direct
```

Here `<NNNN>` is the number the `new` command printed. The regenerate run prints
`regenerated keiro-migrations/expected-schema/native/keiro-v18.txt`; the full migration
suite then reports zero failures with the migration count incremented by one.
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

A row limit bounds response cardinality, not query work. Keep reproducible fixtures and EXPLAIN transcripts outside the fast unit suite. Seed 10,000 and 100,000 rows with skew (one owner has 90% of rows, rare/absent filters, and many equal timestamps), ANALYZE, and measure first and deep pages with `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)` using the actual parameterized query under both `force_custom_plan` and `force_generic_plan`. Run with normal planner settings; `enable_seqscan = off` is a diagnostic only, never acceptance. Record rows examined, rows removed by filter, sort memory/spill, buffers, planning/execution time and query count. Separate absent/present-filter statement shapes where nullable-OR predicates defeat ordered index access. A repeatable dashboard query that scans or sorts the whole ledger at each refresh is not accepted merely because it returns 501 rows. Either provide an evidence-backed matching index, bound the supported filter workload and deadline explicitly, or keep that shape out of automatic feeds. Measure schedule/claim/resume throughput, WAL and HOT-update behavior before and after every index. An immutable index key does not guarantee that index maintenance costs zero on non-HOT updates.

Acceptance also requires parsed CLI invocations for all six `wf inspect` commands, bounded handler query counts and results, and the sibling transport's end-to-end page traversal. With 100,000 children, the header command reads only the instance row; page routes never drain all children or generations. Generation rotation between pages and cross-owner cursor reuse must return the documented mismatch rather than mix histories. Retain legacy rendering tests separately; a compatibility route that drains pages must remain inside the HTTP execution/response budget.


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

Performance acceptance is the realistic prepared-query and write-cost proof above. The old forced-index tests may remain as smoke tests but do not establish bounded scan or sort cost. At most 501 returned rows is a cardinality bound only.

Read-only behavior: the column-comparison example proves no listing changes any instance
row, and the discovery query returns the same set before and after.

Compatibility: the existing `wf list` and `wf journal` examples pass unchanged; the legacy
`listWorkflowInstances` example passes unchanged; no existing exported signature changes.


## Idempotence and Recovery

All reads are repeatable and never write. Tests clone a fresh database per example. The
migration is a `CREATE INDEX IF NOT EXISTS`, so re-applying it is harmless; never edit the
shipped migration file after it ships — a correction is a new migration. If another plan's
migration lands between allocating this plan's number and merging, re-run `keiro-migrate new`
rather than renumbering by hand, and redo the lock line, snapshot, and test counts. If the native snapshot or
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

maxCursorBytes :: Int -- 4096
encodeCursor :: (ToJSON payload) => Text -> payload -> InspectionCursor
encodeCursorBounded :: (ToJSON payload) => Text -> payload -> Maybe InspectionCursor
decodeCursor :: (FromJSON payload) => Text -> InspectionCursor -> Either CursorError payload
```

The registered kind tags across the cohort are `wf-key`, `wf-created`, `wf-steps`,
`wf-journal`, `wf-children`, and `wf-awakeables` (this plan), `aggregate-list` (plan 278),
and `timer-pending` and `pm-list` (plan 274); a new read registers its tag in this list and in
MasterPlan 45's Integration Points before minting tokens.

`keiro-ops/src/Keiro/Ops/Parse.hs` (additive; created by whichever cohort plan first needs
it, so check whether it already exists):

```haskell
-- | Wrap a @--after CURSOR@ option value as an opaque cursor. Performs no
-- validation: the library read that receives it checks the kind and payload
-- and reports 'InvalidCursor'.
cursorReader :: ReadM InspectionCursor
```

`keiro/src/Keiro/Workflow/Inspection.hs` (new, exposed):

```haskell
maxWideWorkflowCandidates, maxWideWorkflowKeyBytes :: Int -- 64 / 256 KiB
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
  | CursorResultTooLarge                 -- stored continuation exceeds the decoder limit
  | InspectionWorkLimitExceeded          -- exceptional workflow key work exceeds its budget
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
`[created_at, workflow_name, workflow_id]`; `wf-steps` carries `[workflow_name, workflow_id, generation, step_name]`;
`wf-journal` carries `[workflow_name, workflow_id, generation, stream_version]`; `wf-children` carries
`[created_at, child_id, child_name]`; `wf-awakeables` carries `[created_at, awakeable_id]`.
The generation inside a journal or step cursor must equal the page's resolved generation,
otherwise `CursorGenerationMismatch resolved cursorGeneration` is returned, so a
`continueAsNew` rotation between two page requests cannot silently splice two journals; the
client restarts on the generation it wants, passing it explicitly.

Schema-module additions (all `Eff`-level, read-only, mirroring the existing lookups):
`Keiro.Workflow.Schema.loadStepIndexPage :: (Store :> es) => WorkflowName -> WorkflowId -> Int -> Maybe Text -> Int -> Eff es [WorkflowStepRow]`,
`Keiro.Workflow.Child.Schema.lookupChildrenOfParentPage :: (Store :> es) => Text -> Text -> Maybe (UTCTime, Text, Text) -> Int -> Eff es [ChildRow]`,
`Keiro.Workflow.Awakeable.Schema.lookupAwakeablesOfOwnerPage :: (Store :> es) => Text -> Text -> Maybe (UTCTime, UUID) -> Int -> Eff es [AwakeableRow]`,
and in `Keiro.Workflow.Instance` separate inspection-only ordering statements and shared row decoding. The legacy `listWorkflowInstances` retains its original SQL and does not call the richer inspection statement. All existing exports of these modules keep their
signatures and behavior.

Hand-off contract: this plan implements the bounded `wf inspect` command subtree and typed failures in M4. Plan 276 parses these commands mechanically into `/wf/inspect/...` routes, preserving page JSON, using `after` for the opaque cursor, and mapping the structured failure codes. No library-only endpoint hand-off remains. Plan 277 consumes `listWorkflowInstancesPage`, `instanceToJson` and `/wf/inspect/list`; its filter field is repeatable `status_class` over the seven classes, not legacy `statuses`.

Dependency sources consulted through Mori: kiroku-store at
`mori://shinzui/kiroku/packages/kiroku-store` (`Kiroku.Store.Read.readStreamForward` takes an
exclusive `StreamVersion` cursor and an `Int32` limit; `StreamVersion` is one-indexed with
`0` meaning "from the first event"; `RecordedEvent` carries `eventId`, `eventType`,
`streamVersion`, and `globalPosition`).


## Revision notes

2026-09-30: Adopted as EP-2 of
[MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md),
which coordinates the keiro-ui inspection cohort (plans 274, 275, 276, 277, 278, 302, and
303). The frontmatter gained `master_plan`; the "Related plans" subsection became a
Coordination subsection restating the settled shared artifacts; the Decision Log gained
entries for the adoption, the cursor kind-tag registry with its create-first rule, the
placement of `cursorReader` in `Keiro.Ops.Parse`, the `instanceToJson` hand-off to plan 277,
and migration-number allocation; Milestone 2, Concrete Steps, and Idempotence now describe the
migration as "the next migration" allocated by `keiro-migrate new` (`0033` was only the next
free number on 2026-09-10, and plans 274 and 299 also add migrations); Interfaces and
Dependencies lists the registered kind tags and the `cursorReader` signature. Why: the five
request plans were written in parallel and disagreed on these artifacts, and the MasterPlan
settles them once so each plan stays independently implementable.

2026-10-13: Applied the correctness and hot-path review. Added explicit performance acceptance and ownership, refreshed released dependency facts, and corrected the affected implementation and wire contracts. Earlier dated decisions remain historical; the current milestones and review constraints govern implementation. No runtime changes or benchmark results are claimed.
