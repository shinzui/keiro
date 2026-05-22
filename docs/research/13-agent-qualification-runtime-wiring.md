# Case study — wiring the `AgentQualification` decomposition onto keiro

Status: worked sketch / validation note. Not a scheduled plan. Companion to
the keiki note
`keiki/docs/research/agent-qualification-decomposition-sketch.md`. Validated
against the live original at
`/Users/shinzui/Keikaku/work/microtan/mls-service-v2-master`
(`mls-service-v2-core/src/MlsService/…`); file pointers below cite it.

The keiki note takes a real production aggregate —
`MlsService.Domain.AgentQualification.AgentQualificationDecider`
(`mls-service-v2`) — and shows how the per-chapter qualification lifecycle
(`NotQualified ⇄ Qualified → Retired`) lands on keiki once the aggregate is
decomposed along `ChapterId`. In doing so it deliberately *pushes four
concerns out of the pure aggregate* (its §4): routing/fan-out, idempotency,
the agent-removal coordinator, and the correction saga. Those four are the
runtime's job — keiro's job. This note runs each of them onto keiro's actual
surface, names what drops onto an existing primitive and the one place a new
primitive is needed, and pins the wiring a novice would write.

The headline: three of the four concerns land cleanly on primitives keiro
already ships (`runCommand`, deterministic command IDs, `ProcessManager`,
inbox/outbox). The fourth — fan-out whose *target set is data-dependent and
must be resolved by a read-model query* — has no home in the current API,
because the only fan-out primitive (`ProcessManager`) computes its target
set with a **pure** function of the triggering event. That gap is the keiro
analog of how the keiki note surfaces a capability gap (symbolic
money/ordering, keiki EP-41): the modeling is sound, one runtime primitive is
missing. It is scoped as the sibling ExecPlan (§10).


## 1. The runtime decomposition map

The keiki note's §4 names what moved out of the aggregate. Each lands here:

| keiki §4 concern | keiro home | Fit |
|---|---|---|
| per-chapter lifecycle — run `QualifyCheck` / `Record*` / `Retire` against one `(member, chapter)` stream | `runCommand` over an `EventStream` (`src/Keiro/Command.hs:264`) | clean |
| routing / fan-out — one transaction → all area-matching `(member, chapter)` streams (`chaptersWithMatchingAreas`) | a **`Router`** (new primitive, §3 + §10) | **gap** |
| idempotency / dedup — the six `Set PropertyId`, by `(propertyId, role)` | deterministic command IDs at dispatch + inbox for the inbound message (§4) | clean |
| agent lifecycle — `MemberRemoved` → `Retire` each chapter stream | a **`Router`** (member→chapters lookup, §5) | **gap** |
| `CorrectInvalidAdjustments` — one correction per invalid `(chapter, property)` | a `Router` triggered by event or timer (§6) | **gap** (same root cause as routing) |

The gap has a single root cause, established in §3 and reused by §5 and §6 —
three consumers, one missing primitive.


## 2. The chapter stream as a keiro `EventStream`

Before any of §4 can dispatch, the keiki transducer from the companion note's
§2 has to become a runnable keiro stream. This is mechanical;
`jitsurei/src/Jitsurei/OrderStream.hs:56` is the template. An `EventStream`
(`src/Keiro/EventStream.hs:14`) bundles the keiki transducer with the
runtime's serialization and snapshot policy:

```haskell
chapterQualEventStream
  :: EventStream (HsPred ChapterQualRegs ChapterQualCmd)
                 ChapterQualRegs Vertex ChapterQualCmd ChapterQualEvent
chapterQualEventStream = EventStream
  { transducer        = chapterQualification          -- keiki note §2, verbatim
  , initialState      = NotQualified
  , initialRegisters  = initialRegs                    -- 8 tallies = 0, qualifiedAt = epoch
  , eventCodec        = chapterQualCodec               -- JSON over ChapterQualEvent
  , resolveStreamName = Stream.streamName
  , snapshotPolicy    = Every 64                       -- tally registers reward snapshotting
  , stateCodec        = Just (defaultStateCodec @ChapterQualRegs @Vertex 1)
  }
```

**Stream identity.** The keiki note's stream key is `(MemberId, ChapterId)`.
keiro's `Stream a` is a newtype over a single `StreamName`
(`src/Keiro/Stream.hs:12`), not a structured key, so the pair is composed
into one name with a category prefix:

```haskell
chapterStream :: MemberId -> ChapterId -> Stream chapterQualEventStream
chapterStream m c = stream ("chapterqual-" <> memberIdText m <> "-" <> chapterIdText c)
```

The `chapterqual-` prefix is the *category* that the projections (§7) and the
publisher (§8) subscribe to. The original aggregate's outer `Map ChapterId`
*is* this set of streams.

**Running one command.** `runCommand opts chapterQualEventStream
(chapterStream m c) cmd` hydrates the stream (snapshot + replay via keiki's
`reconstitute`/`applyEventStreaming`), calls `Keiki.step`, and appends the
emitted event under optimistic concurrency — all inside the one call. The
eight `ChapterSalesData` tallies persist through `defaultStateCodec`; the
`Jitsurei.OrderCart` `itemCount` pattern the keiki note leans on is the same
machinery here, so registers snapshot for free.


## 3. Routing / fan-out — the capability gap

This is the load-bearing finding, so it rests on the actual implementation,
not the design docs.

**The stock fan-out primitive computes its target set purely.** A
`ProcessManager` (`src/Keiro/ProcessManager.hs:40`) does fan out — it returns
a list of target commands — but via a *pure* handler
(`src/Keiro/ProcessManager.hs:46`):

```haskell
handle :: input -> ProcessManagerAction ci targetCi   -- pure
-- ProcessManagerAction { command :: ci, commands :: [PMCommand targetCi], timers :: [TimerRequest] }
```

Routing needs `chaptersWithMatchingAreas(txn)`: a lookup from the
transaction's areas to the set of `(member, chapter)` streams. That mapping
is reference data that changes over time (chapters added, area boundaries
redrawn), so it is a **read model**, and a read-model query is effectful —
`runQuery :: ReadModel q r -> q -> Eff es (Either ReadModelError r)`
(`src/Keiro/ReadModel.hs:57`). A pure `handle` cannot reach it. Nor can the
worker's decode hook `(msg -> Maybe (RecordedEvent, input))`
(`src/Keiro/ProcessManager.hs:193`), which is also pure. **There is no
effectful seam in the stock pipeline between "event arrives" and "targets
computed."**

**The original validates this exactly.** In `mls-service-v2`, routing is
already effectful and already lives *outside* the decider, in the
application layer: `TransactionRecorder.recordTransaction`
(`mls-service-v2-core/src/MlsService/Application/TransactionRecorder.hs:150`)
calls `findChaptersWithQualifyingAreaIds`
(`.../Repository/ChapterRepository.hs:39`), which runs a SQL query against
the `mls_service_read.chapters` read-model table using the Postgres
array-overlap operator — `where $1 && location_service_qualification_area_ids`
(`.../Repository/Tables/Chapter.hs:106`) — and only *then* builds the command
with the matching chapters attached. The matching predicate is richer than
area overlap alone: `shouldRecordTransaction` and `qualifyingChapters` also
filter by property type and close date. The keiro `Router` is the same shape
made first-class: an `Eff es` resolver (a `runQuery`) that produces the
target set, then idempotent dispatch.

**What is reusable: the idempotency machinery, which does not rest on
atomicity.** A correction to a myth the design docs imply: the fan-out is
*not* one multi-stream transaction. `runProcessManagerOnce` appends the
manager's own state in one transaction (`runCommandWithSql`,
`src/Keiro/ProcessManager.hs:125`) and then dispatches each target command in
its **own** `runCommand` (`src/Keiro/ProcessManager.hs:165`) — one
transaction per target. Crash-safety comes entirely from **deterministic
event IDs**:

```haskell
deterministicCommandId :: Text -> Text -> EventId -> Int -> EventId
--                        name    corrId  sourceEvent emitIndex
```

(`src/Keiro/ProcessManager.hs:81`), plus an `eventAlreadyIn` pre-check
(`src/Keiro/ProcessManager.hs:160`) and the store's `DuplicateEvent`
rejection. Replay re-derives the same IDs and skips what is already appended.
This is the correct model: you cannot atomically write N independent
optimistic-concurrency streams, so idempotent replay — not a distributed
transaction — is what makes one-event-in → N-commands-out safe.

**The new primitive (the EP).** Because the idempotent-dispatch loop is
already the right shape and only the *resolution* of the target set needs to
become effectful, the EP introduces a `Router`: a stateless subscriber over a
category that resolves its target set with an `Eff es` action and then reuses
`deterministicCommandId` + per-target `runCommand`. Sketch of the consumer it
unlocks:

```haskell
qualificationRouter :: Router MlsTransaction ChapterQualCmd
qualificationRouter = Router
  { name    = "agent-qual-router"
  , key     = txnKey                                   -- correlation for deterministic IDs
  , resolve = \txn -> do                               -- the effectful seam stock PM lacks
      targets <- runQuery areaChaptersRM (txn ^. #areas)
      pure [ PMCommand (chapterStream m c) (recordCmdFor txn) | (m, c) <- targets ]
  , targetEventStream = chapterQualEventStream
  }
```

Dispatch, deterministic-ID derivation, the `eventAlreadyIn` pre-check, and
`DuplicateEvent` handling are lifted verbatim from `ProcessManager`; the only
new thing is `resolve` living in `Eff es`. The full design — type, runner,
relationship to `ProcessManager`, and the worked `jitsurei` example — is the
sibling ExecPlan (§10).

**A keiki-model note this wiring surfaces.** After each `Record*` the router
also dispatches `QualifyCheck`. The keiki note's `QualifyCheck` edge uses
`requireGuard`, so when the threshold is *not* crossed `Keiki.step` returns
`Nothing` and `runCommand` reports a rejection. That is the normal "not
qualified yet" outcome, not an error — the router must ack it. Cleaner is to
add the **ε-complement self-loop** on `NotQualified` (the negated guard, no
emit) so `QualifyCheck` is total and never surfaces a spurious rejection.
Worth feeding back to the keiki note's §2.


## 4. Idempotency / dedup — two layers

The keiki note's six `Set PropertyId` were pure "already processed?"
plumbing. In keiro that splits into two distinct, complementary layers, and
the note's `(propertyId, role)` maps onto the **second**:

- **Inbound-message dedup (inbox).** "Have I already seen this MLS
  transaction message?" `runInboxTransaction` keys on `(source,
  dedupe_key)` (`src/Keiro/Inbox/Schema.hs:82`), default
  `PreferIntegrationMessageId` (`src/Keiro/Inbox/Types.hs:48`). This guards
  the *ingest* before any fan-out.

- **Per-command dedup (deterministic IDs).** "Have I already recorded *this
  property in this role of this kind* on *this chapter*?" This is exactly the
  six sets. It maps onto the dispatched command's deterministic `EventId` —
  derived from `(chapterId, propertyId, role, txType)` and supplied via
  `RunCommandOptions.eventIds` (the field `runProcessManagerOnce` uses at
  `src/Keiro/ProcessManager.hs:118,157`). The store's unique constraint then
  makes a re-recorded tuple a benign `DuplicateEvent`. No `Set` in the
  aggregate, no extra dedup table — the idempotency is the command's identity.

The `txType` is not a guess: the original's persistent dedup is an **upsert
table** `mls_service_read.agent_qualification_transactions` whose primary key
is `(property_id, member_id, chapter_id, transaction_role, tx_type)`
(`.../Repository/Tables/AgentQualificationTransaction.hs:147`), where
`transaction_role ∈ {Listing, CoListing, PrimaryCoListing, Buyer, CoBuyer,
PrimaryCoBuyer}` and `tx_type ∈ {Recorded, Adjusted, Removed,
CorrectedAdjustment, PriceUpdated}`. The in-decider six `Set PropertyId` are
keyed `(propertyId, role, chapterId)`
(`.../Domain/AgentQualification/AgentQualificationDecider.hs:391`). The keiro
deterministic command ID subsumes both into the command's identity.

So the keiki note's "dedup by `(propertyId, role)` at dispatch" is, precisely,
"choose the dispatch command's `EventId = hash(chapter, property, role,
txType)`." You want both layers: the inbox for the envelope, deterministic IDs
for the fan-out.


## 5. Agent lifecycle — the retire coordinator

`MemberRemoved → Retire` on each of the agent's chapter streams is the
events-in / commands-out shape of `Jitsurei.CoreBankingSync`. In the original
this was **not a fan-out at all**: agent removal was a single *atomic terminal
transition* — `evolve _ (MemberRemoved _) = DeletedAgent`
(`.../Domain/AgentQualification/AgentQualificationDecider.hs:788`) —
discarding every chapter's state at once because it all lived in one
aggregate. The per-chapter `Retire` fan-out is an artifact of decomposing
along `ChapterId`.

The removal trigger is the **external Member context's** `MemberRemoved`,
which the original's `AgentQualificationReadModelPruner`
(`Subscription/AgentQualificationReadModelPruner.hs:39`) consumes to delete
the read-model rows. That context does not know qualification chapters — they
are derived *inside* the AgentQualification context from transactions + area
matching — so the coordinator must **look up the member's chapters in the
`agentChapterStatus` read model** (§7). That look-up is effectful, so the
coordinator is a third consumer of the same seam the router needs (§3): a
`Router`, not a stock `ProcessManager`.

```haskell
retireCoordinator :: Router MemberRemoved ChapterQualCmd
retireCoordinator = Router
  { name    = "agent-qual-retire"
  , key     = memberIdText . (^. #memberId)
  , resolve = \ev -> do                                   -- effectful: queries the read model
      chapters <- runQuery agentChapterStatusRM (ChaptersOf (ev ^. #memberId))
      pure [ PMCommand (chapterStream (ev ^. #memberId) c) (Retire (retireData ev))
           | c <- chapters ]
  , targetEventStream = chapterQualEventStream
  }
```

(Decision recorded 2026-05-20, revised the same day after validating against
the original: an earlier plan to *enrich* `MemberRemoved` with the chapter
list — keeping a pure stock `ProcessManager` — was dropped because it would
force the Member context to carry AgentQualification-specific data, a
cross-context leak the original deliberately avoids. The original's pruner
already gets the chapters by reading the qualification read model; the
decomposed coordinator does the same.) `Retire` is idempotent by
construction: deterministic ID `retire:member:chapter`, and `Retired` is
terminal, so a second `Retire` is a benign duplicate.


## 6. `CorrectInvalidAdjustments` — the correction saga

"Scan all chapters, emit one correction per invalid `(chapter, property)`"
is fan-out plus a query for *which* are invalid — so it is the §3 gap again,
and it is the one piece that may also want a **timer** (`src/Keiro/Timer.hs`,
`jitsurei/src/Jitsurei/Timers.hs`) if corrections run on a schedule rather
than reactively. Model it as a `Router` whose `resolve` queries an
`invalidAdjustments` read model and emits one correction command per
`(chapter, property)` with deterministic ID `correct:chapter:property:rev`.
Each target stream handles a single correction → static output, on-grain. It
is the third consumer that motivates the §10 primitive (with §3 and §5).

Validated against the original: `mkCorrectionEvents` scans
`s ^. #chapterTransactions` per chapter for properties in
`adjustedListingProperties` but not in `soldProperties` (the set difference)
and emits one `InvalidListingAdjustmentCorrected` /
`InvalidBuyerAdjustmentCorrected` per invalid `(chapter, property)`, looking
up the correction amount in a supplied map
(`.../Domain/AgentQualification/AgentQualificationDecider.hs:547`).


## 7. Read models the fan-out needs

The effectful resolutions in §3, §6 imply three projections
(`src/Keiro/Projection.hs`, `src/Keiro/ReadModel.hs`):

1. **`areaChapters`** (area → `[chapter]`) — feeds the router (§3). This is
   the original's `mls_service_read.chapters` table queried by area overlap
   (`.../Repository/Tables/Chapter.hs:106`); built from chapter-definition
   events, or seeded as configuration.
2. **`agentChapterStatus`** (member, chapter → `NotQualified | Qualified`) —
   built from `AgentQualified` / `AgentNoLongerQualified`. This is the read
   surface that *replaces* the original aggregate's `Map ChapterId
   QualificationStatus`; it is the original's `mls_service_read.agent_qualifications`
   table, keyed `(member_id, chapter_id)`, projected by
   `Subscription/AgentQualificationReadModel.hs`. The same projection answers
   "which chapters does this member have?" — the query the retire coordinator
   needs (§5).
3. **`invalidAdjustments`** / **`agentQualificationTransactions`** ((member,
   chapter) → adjusted-vs-recorded properties) — feeds the correction saga
   (§6). This is the original's `agent_qualification_transactions` table
   (`Subscription/AgentQualificationTransactionReadModel.hs`).

The original's `AgentQualificationReadModelPruner`
(`Subscription/AgentQualificationReadModelPruner.hs:39`) is the read-model
side of removal: it listens for the external Member context's `MemberRemoved`
and deletes the member's qualification rows. The decomposed retire coordinator
(§5) is its command-side twin.


## 8. The edges — inbox in, outbox out

- **Ingest.** MLS transactions arrive as integration events over Kafka
  (`src/Keiro/Inbox/Kafka.hs`). `runInboxTransaction` dedups the envelope
  (§4) and records the raw transaction onto an `mls-transaction-*` stream;
  the router (§3) subscribes to that category. Do this as
  inbox → stream → subscription, **not** a bespoke drained adapter: keiro's
  standalone two-stage shibuya inbox adapter was implemented and then
  reverted on YAGNI grounds (`docs/plans/23-add-a-shibuya-inbox-adapter-for-two-stage-integration-event-processing.md`).
- **Publish.** `AgentQualified` / `AgentNoLongerQualified` on the chapter
  streams → an `IntegrationProducer` (`src/Keiro/Outbox.hs:95`) maps them to
  integration events, and `publishClaimedOutbox` (`src/Keiro/Outbox.hs:233`)
  drains them to Kafka. This is the public face the original used: e.g. the
  `AgentQualificationSlackNotifier` fires *only* on `AgentQualified`
  (`Subscription/AgentQualificationSlackNotifier/Notifier.hs:57`) — an
  outbound subscriber, exactly an outbox consumer in keiro terms.

A note on hydration, validated against the original: the
`AgentQualificationAggregateReader`
(`Application/AgentQualificationAggregateReader.hs:40`) uses a hybrid load —
a read-model fast path gated by a `message_version` freshness check, falling
back to full stream replay when stale. keiro gets the same property for free:
snapshot-accelerated hydration on the write path (§2) and `ConsistencyMode`
(`Strong | Eventual | PositionWait`) on the read path
(`src/Keiro/ReadModel.hs:38`).


## 9. What keiro contributes here (the runtime analog of keiki's §3)

Where the keiki note's §3 lists what the *pure core* now verifies, the
runtime contributes the durability and safety guarantees that make the
decomposition shippable:

- **Idempotent fan-out without distributed transactions.** Deterministic
  command IDs (§3) make one-transaction-in → N-commands-out replay-safe
  across crashes, even though each target append is its own transaction.
- **Optimistic concurrency per chapter.** Each `(member, chapter)` stream
  serializes its own writes; concurrent transactions touching different
  chapters never contend.
- **Snapshot-accelerated hydration.** The eight tallies + `qualifiedAt`
  snapshot via `defaultStateCodec`, so a hot chapter does not replay its
  whole history on every command.
- **Effectively-once ingest.** Inbox dedup (§4) + at-least-once Kafka =
  effectively-once processing of each MLS transaction.

What stays an honest gap is exactly one thing: effectful resolution of a
data-dependent fan-out target set (§3, §6). Everything else is wiring over
shipped primitives.


## 10. Follow-up

The keiro capability gap this exercise surfaces is **effectful fan-out
target resolution**: the ability to compute a fan-out's target set with an
`Eff es` action (typically a read-model `runQuery`) instead of the pure
function `ProcessManager` requires today. It is scoped as a sibling ExecPlan,
`docs/plans/26-router-effectful-fan-out-target-resolution.md`, which
introduces a `Keiro.Router` primitive — a stateless category subscriber that
resolves its target set effectfully and dispatches with the existing
idempotency machinery (`deterministicCommandId` + per-target `runCommand` +
`eventAlreadyIn`) — validated by a worked `agent-qual-router` example in
`jitsurei`. It has three consumers in this case study: the transaction router
(§3), the retire coordinator (§5), and the correction saga (§6). All three
share one shape — resolve a target set with `runQuery`, then dispatch
idempotently.

This is the precise mirror of the keiki note's follow-up: there the
decomposition is sound but the *solver* lacks a primitive (symbolic
money/ordering, keiki EP-41); here the decomposition is sound but the
*runtime* lacks a primitive (effectful fan-out resolution). Each side earns
exactly one capability EP.


## Pointers

- `keiki/docs/research/agent-qualification-decomposition-sketch.md` — the
  companion this note pairs with; its §4 is this note's input.
- `keiki/docs/research/effects-boundary.md` — the pure/runtime contract:
  routing, dispatch, idempotency, and time are all the runtime's job.
- `src/Keiro/Command.hs` — `runCommand`, the per-stream command cycle.
- `src/Keiro/ProcessManager.hs` — the fan-out + deterministic-ID machinery
  the `Router` reuses; the retire coordinator (§5) uses it directly.
- `src/Keiro/Inbox.hs`, `src/Keiro/Outbox.hs` — the §8 edges.
- `src/Keiro/ReadModel.hs`, `src/Keiro/Projection.hs` — the §7 projections.
- `jitsurei/src/Jitsurei/OrderStream.hs`, `.../FulfillmentProcess.hs` — the
  `EventStream` and `ProcessManager` templates this note builds on.
- `docs/plans/26-router-effectful-fan-out-target-resolution.md` — the EP.
