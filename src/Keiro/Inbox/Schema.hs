{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE MultilineStrings #-}

{- | Hasql-level storage for the idempotent integration-event inbox.

This module owns the SQL surface that the inbox wrapper
('Keiro.Inbox.runInboxTransaction') and the optional Kafka decoder
('Keiro.Inbox.Kafka') consume.
-}
module Keiro.Inbox.Schema
  ( initializeInboxSchema
  , tryInsertProcessingTx
  , enqueuePendingTx
  , claimInboxBatchTx
  , markCompletedTx
  , markFailedTx
  , markInboxFailedTx
  , markInboxDeadTx
  , releaseInboxClaimTx
  , lookupInbox
  , listInbox
  , listInboxByStatus
  , garbageCollectCompleted
  )
where

import Data.ByteString (ByteString)
import Data.Functor.Contravariant ((>$<))
import Data.Text qualified as Text
import Data.Time.Clock (NominalDiffTime, addUTCTime)
import Data.UUID (UUID)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Keiro.Inbox.Types
import Keiro.Integration.Event
  ( IntegrationEvent (..)
  , SchemaReference (..)
  , TraceContext (..)
  , contentTypeText
  , parseContentType
  )
import Data.Int (Int32)
import Keiro.Outbox.Types (BackoffSchedule, nextDelay)
import Keiro.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..), GlobalPosition (..))

{- | Compatibility helper for development and tests.

Production deployments should run @keiro-migrate@ before application startup.
-}
initializeInboxSchema :: (Store :> es) => Eff es ()
initializeInboxSchema =
  runTransaction $
    Tx.sql
      """
      CREATE TABLE IF NOT EXISTS keiro_inbox (
        source TEXT NOT NULL,
        dedupe_key TEXT NOT NULL,
        message_id TEXT,
        source_event_id UUID,
        source_global_position BIGINT,
        destination TEXT,
        event_type TEXT,
        schema_version BIGINT,
        content_type TEXT NOT NULL,
        schema_registry TEXT,
        schema_subject TEXT,
        schema_version_ref BIGINT,
        schema_id BIGINT,
        schema_fingerprint TEXT,
        causation_id UUID,
        correlation_id UUID,
        traceparent TEXT,
        tracestate TEXT,
        kafka_topic TEXT,
        kafka_partition BIGINT,
        kafka_offset BIGINT,
        payload_bytes BYTEA NOT NULL,
        attributes JSONB,
        occurred_at TIMESTAMPTZ,
        status TEXT NOT NULL DEFAULT 'processing',
        received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        completed_at TIMESTAMPTZ,
        failed_at TIMESTAMPTZ,
        last_error TEXT,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        claimed_at TIMESTAMPTZ,
        PRIMARY KEY (source, dedupe_key)
      );

      CREATE INDEX IF NOT EXISTS keiro_inbox_received_idx
        ON keiro_inbox (received_at);

      CREATE INDEX IF NOT EXISTS keiro_inbox_completed_idx
        ON keiro_inbox (completed_at)
        WHERE status = 'completed';

      CREATE INDEX IF NOT EXISTS keiro_inbox_claimable_idx
        ON keiro_inbox (next_attempt_at, source, dedupe_key)
        WHERE status IN ('pending', 'failed', 'processing');
      """

{- | Attempt to insert a new processing row.

Returns 'Left' carrying the existing row if @(source, dedupe_key)@
already exists; returns 'Right ()' if the insert created a new row. The
caller — typically 'Keiro.Inbox.runInboxTransaction' — then either runs
the handler (new) or branches on the existing row's status (duplicate).
-}
tryInsertProcessingTx ::
  Text ->
  Text ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  UTCTime ->
  Tx.Transaction (Either InboxRow ())
tryInsertProcessingTx src dedupe event kafka now = do
  inserted <-
    Tx.statement (toEncodedInsert src dedupe event kafka now) tryInsertStmt
  if inserted
    then pure (Right ())
    else do
      existing <- Tx.statement (src, dedupe) selectByKeyStmt
      case existing of
        Just row -> pure (Left row)
        Nothing -> pure (Right ())
          -- Race: another worker inserted then deleted the row between
          -- our insert attempt and the lookup. Treat as 'new'; the next
          -- insert in this transaction will reflect the up-to-date
          -- state on commit.

-- | Mark an inbox row completed inside the same transaction as the handler.
markCompletedTx :: Text -> Text -> UTCTime -> Tx.Transaction ()
markCompletedTx src dedupe now =
  Tx.statement (src, dedupe, now) markCompletedStmt

-- | Mark an inbox row failed inside the same transaction as the handler.
markFailedTx :: Text -> Text -> Text -> UTCTime -> Tx.Transaction ()
markFailedTx src dedupe errMsg now =
  Tx.statement (src, dedupe, errMsg, now) markFailedStmt

{- | Insert a fresh @pending@ inbox row.

Used by the two-stage drain path: an upstream producer (Kafka write
side, saga, HTTP shim) records the durable receipt without invoking
the handler. The handler runs later under
'Keiro.Inbox.Adapter.inboxAdapter'.

Returns 'EnqueuedNew' on a fresh insert and 'EnqueueDuplicateOf' when
@(source, dedupe_key)@ already exists. Idempotent under retry.
-}
enqueuePendingTx ::
  Text ->
  Text ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  UTCTime ->
  Tx.Transaction InboxEnqueueOutcome
enqueuePendingTx src dedupe event kafka now = do
  inserted <-
    Tx.statement (toEncodedInsert src dedupe event kafka now) enqueuePendingStmt
  if inserted
    then pure EnqueuedNew
    else do
      existing <- Tx.statement (src, dedupe) selectByKeyStmt
      case existing of
        Just row -> pure (EnqueueDuplicateOf row)
        Nothing ->
          -- Race: the row was deleted between the failed insert and
          -- the lookup. Treat as new — the caller's transaction will
          -- commit; the next call sees the up-to-date state.
          pure EnqueuedNew

{- | Claim up to @batchSize@ rows ready for handler invocation.

A row is claimable when @next_attempt_at <= now@ and its status is one
of:

* @pending@ — never attempted.
* @failed@ — attempted previously and rescheduled by
  'markInboxFailedTx'.
* @processing@ with @claimed_at < now - visibilityTimeout@ — orphaned
  by a crashed worker; reclaim it.

Selection uses @FOR UPDATE SKIP LOCKED@ so concurrent workers do not
contend on the same row. The claimed rows are atomically transitioned
to @processing@ with @claimed_at = now@.
-}
claimInboxBatchTx ::
  InboxClaimOptions ->
  UTCTime ->
  Tx.Transaction [InboxRow]
claimInboxBatchTx opts now =
  Tx.statement
    ( fromIntegral (opts ^. #batchSize)
    , now
    , addUTCTime (negate (opts ^. #visibilityTimeout)) now
    )
    claimStmt

{- | Record a failure on an in-flight claimed row.

Bumps @attempt_count@ and writes @next_attempt_at = now + nextDelay
backoff (attempt_count + 1)@. If the bumped count reaches
@maxAttempts@, the row is parked in 'InboxDead' and returns
'InboxDead'; otherwise it returns 'InboxFailed' (re-claimable after
the delay).

The "row is dead at maxAttempts" predicate uses @>=@ on the
post-increment count, mirroring 'Keiro.Outbox.Schema.markOutboxFailedTx'.
-}
markInboxFailedTx ::
  Text ->
  Text ->
  Text ->
  Int ->
  BackoffSchedule ->
  UTCTime ->
  Tx.Transaction InboxStatus
markInboxFailedTx src dedupe errMsg maxAttempts schedule now = do
  currentAttempt <- Tx.statement (src, dedupe) readAttemptCountStmt
  let bumped = fromMaybe 0 currentAttempt + 1
      shouldDie = bumped >= maxAttempts
      nextStatus = if shouldDie then InboxDead else InboxFailed
      nextAttempt = addUTCTime (nextDelay schedule bumped) now
  Tx.statement
    ( src
    , dedupe
    , inboxStatusText nextStatus
    , errMsg
    , nextAttempt
    , now
    , fromIntegral bumped
    )
    markInboxFailedStmt
  pure nextStatus

-- | Move a row directly to the terminal @dead@ status.
markInboxDeadTx :: Text -> Text -> Text -> UTCTime -> Tx.Transaction ()
markInboxDeadTx src dedupe errMsg now =
  Tx.statement (src, dedupe, errMsg, now) markInboxDeadStmt

{- | Release a claim without bumping @attempt_count@.

Used for 'Shibuya.Core.Ack.AckHalt': the worker decided to stop, but
the row itself is fine. Status flips @processing@ → @pending@, and
@next_attempt_at@ becomes @now@ so the next claim cycle can re-pick
the row.
-}
releaseInboxClaimTx :: Text -> Text -> UTCTime -> Tx.Transaction ()
releaseInboxClaimTx src dedupe now =
  Tx.statement (src, dedupe, now) releaseInboxClaimStmt

-- | Read one inbox row.
lookupInbox :: (Store :> es) => Text -> Text -> Eff es (Maybe InboxRow)
lookupInbox src dedupe =
  runTransaction $
    Tx.statement (src, dedupe) selectByKeyStmt

-- | List inbox rows for a source, ordered by @received_at@. Test helper.
listInbox :: (Store :> es) => Text -> Eff es [InboxRow]
listInbox src =
  runTransaction $
    Tx.statement src listBySourceStmt

-- | List inbox rows matching a status (test/inspection helper).
listInboxByStatus :: (Store :> es) => InboxStatus -> Eff es [InboxRow]
listInboxByStatus status =
  runTransaction $
    Tx.statement (inboxStatusText status) listByStatusStmt

{- | Delete completed inbox rows older than @keepFor@ from @now@.

Returns the number of rows deleted. The retention window defines the
duplicate-detection window: a redelivery that arrives after retention
GC has run will be processed again, so the window must exceed the
maximum delivery delay tolerated by the operator. The user guide
recommends 30 days as a default.
-}
garbageCollectCompleted ::
  (Store :> es) =>
  NominalDiffTime ->
  UTCTime ->
  Eff es Int
garbageCollectCompleted keepFor now = do
  let cutoff = addUTCTime (negate keepFor) now
  result <-
    runTransaction $
      Tx.statement cutoff gcStmt
  pure (fromIntegral result)

-- ---------------------------------------------------------------------------
-- Encoder support
-- ---------------------------------------------------------------------------

data EncodedInsert = EncodedInsert
  { source :: !Text
  , dedupeKey :: !Text
  , messageId :: !(Maybe Text)
  , sourceEventId :: !(Maybe UUID)
  , sourceGlobalPosition :: !(Maybe Int64)
  , destination :: !(Maybe Text)
  , eventType :: !(Maybe Text)
  , schemaVersion :: !(Maybe Int64)
  , contentType :: !Text
  , schemaRegistry :: !(Maybe Text)
  , schemaSubject :: !(Maybe Text)
  , schemaVersionRef :: !(Maybe Int64)
  , schemaId :: !(Maybe Int64)
  , schemaFingerprint :: !(Maybe Text)
  , causationId :: !(Maybe UUID)
  , correlationId :: !(Maybe UUID)
  , traceparent :: !(Maybe Text)
  , tracestate :: !(Maybe Text)
  , kafkaTopic :: !(Maybe Text)
  , kafkaPartition :: !(Maybe Int64)
  , kafkaOffset :: !(Maybe Int64)
  , payloadBytes :: !ByteString
  , attributes :: !(Maybe Value)
  , occurredAt :: !(Maybe UTCTime)
  , receivedAt :: !UTCTime
  }
  deriving stock (Generic)

toEncodedInsert ::
  Text ->
  Text ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  UTCTime ->
  EncodedInsert
toEncodedInsert src dedupe event kafka now =
  let mref = event ^. #schemaReference
      mtrace = event ^. #traceContext
   in EncodedInsert
        { source = src
        , dedupeKey = dedupe
        , messageId = nullIfEmpty (event ^. #messageId)
        , sourceEventId = fmap unEventId (event ^. #sourceEventId)
        , sourceGlobalPosition = fmap unGlobalPosition (event ^. #sourceGlobalPosition)
        , destination = nullIfEmpty (event ^. #destination)
        , eventType = nullIfEmpty (event ^. #eventType)
        , schemaVersion = Just (fromIntegral (event ^. #schemaVersion))
        , contentType = contentTypeText (event ^. #contentType)
        , schemaRegistry = mref >>= (^. #registry)
        , schemaSubject = mref >>= (^. #subject)
        , schemaVersionRef = fmap fromIntegral (mref >>= (^. #version))
        , schemaId = mref >>= (^. #schemaId)
        , schemaFingerprint = mref >>= (^. #fingerprint)
        , causationId = fmap unEventId (event ^. #causationId)
        , correlationId = fmap unEventId (event ^. #correlationId)
        , traceparent = fmap (^. #traceparent) mtrace
        , tracestate = mtrace >>= (^. #tracestate)
        , kafkaTopic = fmap (^. #topic) kafka
        , kafkaPartition = fmap (^. #partition) kafka
        , kafkaOffset = fmap (^. #offset) kafka
        , payloadBytes = event ^. #payloadBytes
        , attributes = event ^. #attributes
        , occurredAt = Just (event ^. #occurredAt)
        , receivedAt = now
        }

nullIfEmpty :: Text -> Maybe Text
nullIfEmpty t = if t == mempty then Nothing else Just t

unEventId :: EventId -> UUID
unEventId (EventId u) = u

unGlobalPosition :: GlobalPosition -> Int64
unGlobalPosition (GlobalPosition i) = i

encodedInsertEncoder :: E.Params EncodedInsert
encodedInsertEncoder =
  mconcat
    [ view #source >$< E.param (E.nonNullable E.text)
    , view #dedupeKey >$< E.param (E.nonNullable E.text)
    , view #messageId >$< E.param (E.nullable E.text)
    , view #sourceEventId >$< E.param (E.nullable E.uuid)
    , view #sourceGlobalPosition >$< E.param (E.nullable E.int8)
    , view #destination >$< E.param (E.nullable E.text)
    , view #eventType >$< E.param (E.nullable E.text)
    , view #schemaVersion >$< E.param (E.nullable E.int8)
    , view #contentType >$< E.param (E.nonNullable E.text)
    , view #schemaRegistry >$< E.param (E.nullable E.text)
    , view #schemaSubject >$< E.param (E.nullable E.text)
    , view #schemaVersionRef >$< E.param (E.nullable E.int8)
    , view #schemaId >$< E.param (E.nullable E.int8)
    , view #schemaFingerprint >$< E.param (E.nullable E.text)
    , view #causationId >$< E.param (E.nullable E.uuid)
    , view #correlationId >$< E.param (E.nullable E.uuid)
    , view #traceparent >$< E.param (E.nullable E.text)
    , view #tracestate >$< E.param (E.nullable E.text)
    , view #kafkaTopic >$< E.param (E.nullable E.text)
    , view #kafkaPartition >$< E.param (E.nullable E.int8)
    , view #kafkaOffset >$< E.param (E.nullable E.int8)
    , view #payloadBytes >$< E.param (E.nonNullable E.bytea)
    , view #attributes >$< E.param (E.nullable E.jsonb)
    , view #occurredAt >$< E.param (E.nullable E.timestamptz)
    , view #receivedAt >$< E.param (E.nonNullable E.timestamptz)
    ]

-- ---------------------------------------------------------------------------
-- Statements
-- ---------------------------------------------------------------------------

tryInsertStmt :: Statement EncodedInsert Bool
tryInsertStmt =
  preparable
    """
    INSERT INTO keiro_inbox
      ( source
      , dedupe_key
      , message_id
      , source_event_id
      , source_global_position
      , destination
      , event_type
      , schema_version
      , content_type
      , schema_registry
      , schema_subject
      , schema_version_ref
      , schema_id
      , schema_fingerprint
      , causation_id
      , correlation_id
      , traceparent
      , tracestate
      , kafka_topic
      , kafka_partition
      , kafka_offset
      , payload_bytes
      , attributes
      , occurred_at
      , received_at
      )
    VALUES
      ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24, $25)
    ON CONFLICT (source, dedupe_key) DO NOTHING
    RETURNING TRUE
    """
    encodedInsertEncoder
    (fmap (fromMaybe False) (D.rowMaybe (D.column (D.nonNullable D.bool))))

markCompletedStmt :: Statement (Text, Text, UTCTime) ()
markCompletedStmt =
  preparable
    """
    UPDATE keiro_inbox
    SET status = 'completed',
        completed_at = $3,
        last_error = NULL
    WHERE source = $1 AND dedupe_key = $2
    """
    ( ((\(s, _, _) -> s) >$< E.param (E.nonNullable E.text))
        <> ((\(_, d, _) -> d) >$< E.param (E.nonNullable E.text))
        <> ((\(_, _, t) -> t) >$< E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

markFailedStmt :: Statement (Text, Text, Text, UTCTime) ()
markFailedStmt =
  preparable
    """
    UPDATE keiro_inbox
    SET status = 'failed',
        failed_at = $4,
        last_error = $3
    WHERE source = $1 AND dedupe_key = $2
    """
    ( ((\(s, _, _, _) -> s) >$< E.param (E.nonNullable E.text))
        <> ((\(_, d, _, _) -> d) >$< E.param (E.nonNullable E.text))
        <> ((\(_, _, e, _) -> e) >$< E.param (E.nonNullable E.text))
        <> ((\(_, _, _, t) -> t) >$< E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

selectByKeyStmt :: Statement (Text, Text) (Maybe InboxRow)
selectByKeyStmt =
  preparable
    (selectAllSql <> " WHERE source = $1 AND dedupe_key = $2")
    ( (fst >$< E.param (E.nonNullable E.text))
        <> (snd >$< E.param (E.nonNullable E.text))
    )
    (D.rowMaybe inboxRowDecoder)

listBySourceStmt :: Statement Text [InboxRow]
listBySourceStmt =
  preparable
    (selectAllSql <> " WHERE source = $1 ORDER BY received_at, dedupe_key")
    (E.param (E.nonNullable E.text))
    (D.rowList inboxRowDecoder)

listByStatusStmt :: Statement Text [InboxRow]
listByStatusStmt =
  preparable
    (selectAllSql <> " WHERE status = $1 ORDER BY received_at, dedupe_key")
    (E.param (E.nonNullable E.text))
    (D.rowList inboxRowDecoder)

enqueuePendingStmt :: Statement EncodedInsert Bool
enqueuePendingStmt =
  preparable
    (Text.unwords
      [ "INSERT INTO keiro_inbox"
      , "  ( source"
      , "  , dedupe_key"
      , "  , message_id"
      , "  , source_event_id"
      , "  , source_global_position"
      , "  , destination"
      , "  , event_type"
      , "  , schema_version"
      , "  , content_type"
      , "  , schema_registry"
      , "  , schema_subject"
      , "  , schema_version_ref"
      , "  , schema_id"
      , "  , schema_fingerprint"
      , "  , causation_id"
      , "  , correlation_id"
      , "  , traceparent"
      , "  , tracestate"
      , "  , kafka_topic"
      , "  , kafka_partition"
      , "  , kafka_offset"
      , "  , payload_bytes"
      , "  , attributes"
      , "  , occurred_at"
      , "  , received_at"
      , "  , status"
      , "  , next_attempt_at"
      , "  )"
      , "VALUES"
      , "  ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24, $25, 'pending', $25)"
      , "ON CONFLICT (source, dedupe_key) DO NOTHING"
      , "RETURNING TRUE"
      ])
    encodedInsertEncoder
    (fmap (fromMaybe False) (D.rowMaybe (D.column (D.nonNullable D.bool))))

claimStmt :: Statement (Int64, UTCTime, UTCTime) [InboxRow]
claimStmt =
  preparable
    (Text.unwords
      [ "WITH ready AS ("
      , "  SELECT source, dedupe_key FROM keiro_inbox"
      , "  WHERE next_attempt_at <= $2"
      , "    AND ( status = 'pending'"
      , "       OR status = 'failed'"
      , "       OR (status = 'processing' AND claimed_at IS NOT NULL AND claimed_at < $3) )"
      , "  ORDER BY next_attempt_at, source, dedupe_key"
      , "  LIMIT $1"
      , "  FOR UPDATE SKIP LOCKED"
      , ")"
      , "UPDATE keiro_inbox kt"
      , "SET status = 'processing', claimed_at = $2"
      , "FROM ready"
      , "WHERE kt.source = ready.source AND kt.dedupe_key = ready.dedupe_key"
      , "RETURNING kt.source, kt.dedupe_key, kt.message_id, kt.source_event_id,"
      , "  kt.source_global_position, kt.destination, kt.event_type, kt.schema_version,"
      , "  kt.content_type, kt.schema_registry, kt.schema_subject, kt.schema_version_ref,"
      , "  kt.schema_id, kt.schema_fingerprint, kt.causation_id, kt.correlation_id,"
      , "  kt.traceparent, kt.tracestate, kt.kafka_topic, kt.kafka_partition,"
      , "  kt.kafka_offset, kt.payload_bytes, kt.attributes, kt.occurred_at, kt.status,"
      , "  kt.received_at, kt.completed_at, kt.failed_at, kt.last_error,"
      , "  kt.attempt_count, kt.next_attempt_at, kt.claimed_at"
      ])
    ( ((\(lim, _, _) -> lim) >$< E.param (E.nonNullable E.int8))
        <> ((\(_, n, _) -> n) >$< E.param (E.nonNullable E.timestamptz))
        <> ((\(_, _, c) -> c) >$< E.param (E.nonNullable E.timestamptz))
    )
    (D.rowList inboxRowDecoder)

readAttemptCountStmt :: Statement (Text, Text) (Maybe Int)
readAttemptCountStmt =
  preparable
    "SELECT attempt_count FROM keiro_inbox WHERE source = $1 AND dedupe_key = $2"
    ( (fst >$< E.param (E.nonNullable E.text))
        <> (snd >$< E.param (E.nonNullable E.text))
    )
    (D.rowMaybe (fromIntegral <$> D.column (D.nonNullable D.int4)))

markInboxFailedStmt :: Statement (Text, Text, Text, Text, UTCTime, UTCTime, Int32) ()
markInboxFailedStmt =
  preparable
    """
    UPDATE keiro_inbox
    SET status = $3,
        last_error = $4,
        next_attempt_at = $5,
        failed_at = $6,
        claimed_at = NULL,
        attempt_count = $7
    WHERE source = $1 AND dedupe_key = $2
    """
    ( ((\(s, _, _, _, _, _, _) -> s) >$< E.param (E.nonNullable E.text))
        <> ((\(_, d, _, _, _, _, _) -> d) >$< E.param (E.nonNullable E.text))
        <> ((\(_, _, st, _, _, _, _) -> st) >$< E.param (E.nonNullable E.text))
        <> ((\(_, _, _, e, _, _, _) -> e) >$< E.param (E.nonNullable E.text))
        <> ((\(_, _, _, _, n, _, _) -> n) >$< E.param (E.nonNullable E.timestamptz))
        <> ((\(_, _, _, _, _, f, _) -> f) >$< E.param (E.nonNullable E.timestamptz))
        <> ((\(_, _, _, _, _, _, a) -> a) >$< E.param (E.nonNullable E.int4))
    )
    D.noResult

markInboxDeadStmt :: Statement (Text, Text, Text, UTCTime) ()
markInboxDeadStmt =
  preparable
    """
    UPDATE keiro_inbox
    SET status = 'dead',
        last_error = $3,
        failed_at = $4,
        claimed_at = NULL
    WHERE source = $1 AND dedupe_key = $2
    """
    ( ((\(s, _, _, _) -> s) >$< E.param (E.nonNullable E.text))
        <> ((\(_, d, _, _) -> d) >$< E.param (E.nonNullable E.text))
        <> ((\(_, _, e, _) -> e) >$< E.param (E.nonNullable E.text))
        <> ((\(_, _, _, t) -> t) >$< E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

releaseInboxClaimStmt :: Statement (Text, Text, UTCTime) ()
releaseInboxClaimStmt =
  preparable
    """
    UPDATE keiro_inbox
    SET status = 'pending',
        claimed_at = NULL,
        next_attempt_at = $3
    WHERE source = $1 AND dedupe_key = $2 AND status = 'processing'
    """
    ( ((\(s, _, _) -> s) >$< E.param (E.nonNullable E.text))
        <> ((\(_, d, _) -> d) >$< E.param (E.nonNullable E.text))
        <> ((\(_, _, t) -> t) >$< E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

gcStmt :: Statement UTCTime Int64
gcStmt =
  preparable
    """
    WITH deleted AS (
      DELETE FROM keiro_inbox
      WHERE status = 'completed' AND completed_at < $1
      RETURNING 1
    )
    SELECT COALESCE(COUNT(*), 0)::bigint FROM deleted
    """
    (E.param (E.nonNullable E.timestamptz))
    (D.singleRow (D.column (D.nonNullable D.int8)))

selectAllSql :: Text
selectAllSql =
  "SELECT source, dedupe_key, message_id, source_event_id, source_global_position, \
  \destination, event_type, schema_version, content_type, schema_registry, \
  \schema_subject, schema_version_ref, schema_id, schema_fingerprint, causation_id, \
  \correlation_id, traceparent, tracestate, kafka_topic, kafka_partition, \
  \kafka_offset, payload_bytes, attributes, occurred_at, status, received_at, \
  \completed_at, failed_at, last_error, attempt_count, next_attempt_at, claimed_at \
  \FROM keiro_inbox"

inboxRowDecoder :: D.Row InboxRow
inboxRowDecoder = fmap assembleInboxRow rawDecoder

data RawInbox = RawInbox
  { source :: !Text
  , dedupeKey :: !Text
  , messageId :: !(Maybe Text)
  , sourceEventId :: !(Maybe EventId)
  , sourceGlobalPosition :: !(Maybe GlobalPosition)
  , destination :: !(Maybe Text)
  , eventType :: !(Maybe Text)
  , schemaVersion :: !(Maybe Int)
  , contentType :: !Text
  , schemaRegistry :: !(Maybe Text)
  , schemaSubject :: !(Maybe Text)
  , schemaVersionRef :: !(Maybe Int)
  , schemaId :: !(Maybe Int64)
  , schemaFingerprint :: !(Maybe Text)
  , causationId :: !(Maybe EventId)
  , correlationId :: !(Maybe EventId)
  , traceparent :: !(Maybe Text)
  , tracestate :: !(Maybe Text)
  , kafkaTopic :: !(Maybe Text)
  , kafkaPartition :: !(Maybe Int64)
  , kafkaOffset :: !(Maybe Int64)
  , payloadBytes :: !ByteString
  , attributes :: !(Maybe Value)
  , occurredAt :: !(Maybe UTCTime)
  , status :: !InboxStatus
  , receivedAt :: !UTCTime
  , completedAt :: !(Maybe UTCTime)
  , failedAt :: !(Maybe UTCTime)
  , lastError :: !(Maybe Text)
  , attemptCount :: !Int
  , nextAttemptAt :: !UTCTime
  , claimedAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic)

rawDecoder :: D.Row RawInbox
rawDecoder =
  RawInbox
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> (fmap EventId <$> D.column (D.nullable D.uuid))
    <*> (fmap GlobalPosition <$> D.column (D.nullable D.int8))
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> (fmap fromIntegral <$> D.column (D.nullable D.int8))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> (fmap fromIntegral <$> D.column (D.nullable D.int8))
    <*> D.column (D.nullable D.int8)
    <*> D.column (D.nullable D.text)
    <*> (fmap EventId <$> D.column (D.nullable D.uuid))
    <*> (fmap EventId <$> D.column (D.nullable D.uuid))
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.int8)
    <*> D.column (D.nullable D.int8)
    <*> D.column (D.nonNullable D.bytea)
    <*> D.column (D.nullable D.jsonb)
    <*> D.column (D.nullable D.timestamptz)
    <*> (parseInboxStatus <$> D.column (D.nonNullable D.text))
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.text)
    <*> (fromIntegral <$> D.column (D.nonNullable D.int4))
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)

assembleInboxRow :: RawInbox -> InboxRow
assembleInboxRow raw =
  let traceContext = case raw ^. #traceparent of
        Nothing -> Nothing
        Just tp -> Just (TraceContext tp (raw ^. #tracestate))
      schemaReference =
        case
          ( raw ^. #schemaRegistry
          , raw ^. #schemaSubject
          , raw ^. #schemaVersionRef
          , raw ^. #schemaId
          , raw ^. #schemaFingerprint
          )
          of
            (Nothing, Nothing, Nothing, Nothing, Nothing) -> Nothing
            _ ->
              Just
                ( SchemaReference
                    (raw ^. #schemaRegistry)
                    (raw ^. #schemaSubject)
                    (raw ^. #schemaVersionRef)
                    (raw ^. #schemaId)
                    (raw ^. #schemaFingerprint)
                )
      kafka =
        case (raw ^. #kafkaTopic, raw ^. #kafkaPartition, raw ^. #kafkaOffset) of
          (Just t, Just p, Just o) -> Just (KafkaDeliveryRef t p o)
          _ -> Nothing
      event =
        IntegrationEvent
          { messageId = fromMaybe mempty (raw ^. #messageId)
          , source = raw ^. #source
          , destination = fromMaybe mempty (raw ^. #destination)
          , key = Nothing
            -- @key@ is not part of the inbox primary key and is not
            -- carried separately on the row — the same partition info
            -- lives in @kafka@. Receivers that need it can re-derive
            -- from the payload.
          , eventType = fromMaybe mempty (raw ^. #eventType)
          , schemaVersion = fromMaybe 0 (raw ^. #schemaVersion)
          , contentType = parseContentType (raw ^. #contentType)
          , schemaReference
          , sourceEventId = raw ^. #sourceEventId
          , sourceGlobalPosition = raw ^. #sourceGlobalPosition
          , payloadBytes = raw ^. #payloadBytes
          , occurredAt = fromMaybe defaultEpoch (raw ^. #occurredAt)
          , causationId = raw ^. #causationId
          , correlationId = raw ^. #correlationId
          , traceContext
          , attributes = raw ^. #attributes
          }
   in InboxRow
        { source = raw ^. #source
        , dedupeKey = raw ^. #dedupeKey
        , event
        , kafka
        , status = raw ^. #status
        , receivedAt = raw ^. #receivedAt
        , completedAt = raw ^. #completedAt
        , failedAt = raw ^. #failedAt
        , lastError = raw ^. #lastError
        , attemptCount = raw ^. #attemptCount
        , nextAttemptAt = raw ^. #nextAttemptAt
        , claimedAt = raw ^. #claimedAt
        }

-- | Sentinel used when an inbox row was written without an @occurred_at@.
--
-- Inbox rows are observability-shaped; consumers that care should
-- re-read the timestamp from the envelope payload directly.
defaultEpoch :: UTCTime
defaultEpoch = read "1970-01-01 00:00:00 UTC"
