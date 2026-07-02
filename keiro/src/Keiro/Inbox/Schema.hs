{-# LANGUAGE ApplicativeDo #-}

{- | Hasql-level storage for the idempotent integration-event inbox.

This module owns the SQL surface that the inbox wrapper
('Keiro.Inbox.runInboxTransaction') and the optional Kafka decoder
('Keiro.Inbox.Kafka') consume.
-}
module Keiro.Inbox.Schema (
    tryInsertCompletedTx,
    markCompletedTx,
    markFailedTx,
    recordFailedAttemptTx,
    lookupInbox,
    listInbox,
    garbageCollectCompleted,
    countInboxBacklog,
)
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4)
import Data.ByteString (ByteString)
import Data.Functor.Contravariant ((>$<))
import Data.Time.Clock (NominalDiffTime, addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.UUID (UUID)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Inbox.Types
import Keiro.Integration.Event (
    IntegrationEvent (..),
    SchemaReference (..),
    TraceContext (..),
    contentTypeText,
    parseContentType,
 )
import Keiro.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..), GlobalPosition (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx

{- | Attempt to insert a new completed row.

Returns 'Left' carrying the existing row if @(source, dedupe_key)@
already exists; returns 'Right ()' if the insert created a new row. The
caller — typically 'Keiro.Inbox.runInboxTransaction' — then either runs
the handler (new) or branches on the existing row's status (duplicate).

The row is inserted as @completed@ before the handler runs, but remains
uncommitted until the handler transaction succeeds. On handler failure the
whole transaction rolls back, so the completed row never becomes visible.

If a concurrent retention job deletes the conflicting row between the
insert attempt and the lookup, this returns 'Right ()'. The handler then
runs without recording that delivery. That edge is acceptable because
retention only removes rows outside the configured dedupe window.
-}
tryInsertCompletedTx ::
    Text ->
    Text ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    UTCTime ->
    Tx.Transaction (Either InboxRow ())
tryInsertCompletedTx src dedupe event kafka now = do
    inserted <-
        Tx.statement (toEncodedInsert src dedupe event kafka now) tryInsertStmt
    if inserted
        then pure (Right ())
        else do
            existing <- Tx.statement (src, dedupe) selectByKeyStmt
            case existing of
                Just row -> pure (Left row)
                Nothing -> pure (Right ())

-- | Mark an inbox row completed inside the same transaction as the handler.
markCompletedTx :: Text -> Text -> UTCTime -> Tx.Transaction ()
markCompletedTx src dedupe now =
    Tx.statement (src, dedupe, now) markCompletedStmt

-- | Mark an inbox row failed inside the same transaction as the handler.
markFailedTx :: Text -> Text -> Text -> UTCTime -> Tx.Transaction ()
markFailedTx src dedupe errMsg now =
    Tx.statement (src, dedupe, errMsg, now) markFailedStmt

{- | Record one failed handler attempt for @(source, dedupe_key)@.

Creates a failed row when the handler transaction rolled back the initial
processing insert, or increments the existing failed row's attempt count.
Returns the new attempt count.
-}
recordFailedAttemptTx ::
    Text ->
    Text ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    Text ->
    UTCTime ->
    Tx.Transaction Int
recordFailedAttemptTx src dedupe event kafka errMsg now =
    Tx.statement (toEncodedFailedInsert src dedupe event kafka errMsg now) recordFailedAttemptStmt

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

{- | Count inbox rows in a non-terminal state (backlog gauge source).

Backlog = rows still @processing@ (in flight) or @failed@ (awaiting a
retry decision). Completed rows are terminal and excluded.
-}
countInboxBacklog :: (Store :> es) => Eff es Int
countInboxBacklog =
    runTransaction (Tx.statement () countInboxBacklogStmt)

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

data EncodedFailedInsert = EncodedFailedInsert
    { insert :: !EncodedInsert
    , lastError :: !Text
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

toEncodedFailedInsert ::
    Text ->
    Text ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    Text ->
    UTCTime ->
    EncodedFailedInsert
toEncodedFailedInsert src dedupe event kafka errMsg now =
    EncodedFailedInsert
        { insert = toEncodedInsert src dedupe event kafka now
        , lastError = errMsg
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

encodedFailedInsertEncoder :: E.Params EncodedFailedInsert
encodedFailedInsertEncoder =
    (view #insert >$< encodedInsertEncoder)
        <> (view #lastError >$< E.param (E.nonNullable E.text))

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
          , status
          , completed_at
          )
        VALUES
          ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24, $25, 'completed', $25)
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
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.timestamptz))
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
        ( contrazip4
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.timestamptz))
        )
        D.noResult

recordFailedAttemptStmt :: Statement EncodedFailedInsert Int
recordFailedAttemptStmt =
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
          , status
          , attempt_count
          , failed_at
          , last_error
          )
        VALUES
          ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24, $25, 'failed', 1, $25, $26)
        ON CONFLICT (source, dedupe_key) DO UPDATE
        SET status = 'failed',
            attempt_count = keiro_inbox.attempt_count + 1,
            last_error = EXCLUDED.last_error,
            failed_at = EXCLUDED.failed_at
        RETURNING attempt_count
        """
        encodedFailedInsertEncoder
        (fmap fromIntegral (D.singleRow (D.column (D.nonNullable D.int8))))

selectByKeyStmt :: Statement (Text, Text) (Maybe InboxRow)
selectByKeyStmt =
    preparable
        (selectAllSql <> " WHERE source = $1 AND dedupe_key = $2")
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        (D.rowMaybe inboxRowDecoder)

listBySourceStmt :: Statement Text [InboxRow]
listBySourceStmt =
    preparable
        (selectAllSql <> " WHERE source = $1 ORDER BY received_at, dedupe_key")
        (E.param (E.nonNullable E.text))
        (D.rowList inboxRowDecoder)

countInboxBacklogStmt :: Statement () Int
countInboxBacklogStmt =
    preparable
        "SELECT COUNT(*)::bigint FROM keiro_inbox WHERE status IN ('processing', 'failed')"
        E.noParams
        (fmap fromIntegral (D.singleRow (D.column (D.nonNullable D.int8))))

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
    """
    SELECT source, dedupe_key, message_id, source_event_id, source_global_position,
           destination, event_type, schema_version, content_type, schema_registry,
           schema_subject, schema_version_ref, schema_id, schema_fingerprint,
           causation_id, correlation_id, traceparent, tracestate, kafka_topic,
           kafka_partition, kafka_offset, payload_bytes, attributes, occurred_at,
           status, attempt_count, received_at, completed_at, failed_at, last_error
    FROM keiro_inbox
    """

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
    , attemptCount :: !Int
    , receivedAt :: !UTCTime
    , completedAt :: !(Maybe UTCTime)
    , failedAt :: !(Maybe UTCTime)
    , lastError :: !(Maybe Text)
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
        <*> D.column (D.nonNullable (D.refine parseInboxStatus D.text))
        <*> (fromIntegral <$> D.column (D.nonNullable D.int8))
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nullable D.timestamptz)
        <*> D.column (D.nullable D.timestamptz)
        <*> D.column (D.nullable D.text)

assembleInboxRow :: RawInbox -> InboxRow
assembleInboxRow raw =
    let traceContext = case raw ^. #traceparent of
            Nothing -> Nothing
            Just tp -> Just (TraceContext tp (raw ^. #tracestate))
        schemaReference =
            case ( raw ^. #schemaRegistry
                 , raw ^. #schemaSubject
                 , raw ^. #schemaVersionRef
                 , raw ^. #schemaId
                 , raw ^. #schemaFingerprint
                 ) of
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
                , -- @key@ is not part of the inbox primary key and is not
                  -- carried separately on the row — the same partition info
                  -- lives in @kafka@. Receivers that need it can re-derive
                  -- from the payload.
                  eventType = fromMaybe mempty (raw ^. #eventType)
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
            , attemptCount = raw ^. #attemptCount
            , receivedAt = raw ^. #receivedAt
            , completedAt = raw ^. #completedAt
            , failedAt = raw ^. #failedAt
            , lastError = raw ^. #lastError
            }

{- | Sentinel used when an inbox row was written without an @occurred_at@.

Inbox rows are observability-shaped; consumers that care should
re-read the timestamp from the envelope payload directly.
-}
defaultEpoch :: UTCTime
defaultEpoch = posixSecondsToUTCTime 0
