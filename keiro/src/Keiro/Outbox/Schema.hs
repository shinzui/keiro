{-# LANGUAGE ApplicativeDo #-}

{- | Hasql-level storage for the durable integration-event outbox.

This module owns the SQL surface that publishers call into. Higher-level
helpers ('Keiro.Outbox') and transport adapters
('Keiro.Outbox.Kafka') consume these primitives.
-}
module Keiro.Outbox.Schema (
    enqueueOutboxTx,
    claimOutboxBatch,
    requeueStuckOutbox,
    markOutboxSent,
    markOutboxFailedTx,
    lookupOutbox,
    listOutbox,
    countOutboxBacklog,
    garbageCollectSent,
)
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip5)
import Data.ByteString (ByteString)
import Data.Functor.Contravariant ((>$<))
import Data.Time.Clock (NominalDiffTime, addUTCTime)
import Data.UUID (UUID)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Integration.Event (
    IntegrationEvent (..),
    SchemaReference (..),
    TraceContext (..),
    contentTypeText,
    parseContentType,
 )
import Keiro.Outbox.Types
import Keiro.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..), GlobalPosition (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx

{- | Enqueue one integration event inside an existing transaction.

The @(source, message_id)@ unique constraint catches duplicate retries
from a saga/process-manager. Callers that mint a fresh @messageId@ per
attempt should also mint a fresh @outboxId@; callers that want
idempotent retries should reuse both.
-}
enqueueOutboxTx :: OutboxMessage -> Tx.Transaction ()
enqueueOutboxTx message =
    Tx.statement (toEncodedRow message) enqueueOutboxStmt

-- | Read a single outbox row by id. Used by tests and inspection tooling.
lookupOutbox :: (Store :> es) => OutboxId -> Eff es (Maybe OutboxRow)
lookupOutbox outboxId =
    runTransaction $
        Tx.statement (unOutboxId outboxId) lookupOutboxStmt

{- | List outbox rows for a source, ordered by @created_at@. Used by tests;
not intended for application traffic.
-}
listOutbox :: (Store :> es) => Text -> Eff es [OutboxRow]
listOutbox source =
    runTransaction $
        Tx.statement source listOutboxStmt

{- | Count outbox rows awaiting publish (backlog gauge source).

Backlog = rows in a claimable, non-terminal state. Mirrors the claim
query's @status IN ('pending','failed')@ predicate so the gauge measures
exactly the rows a publisher still has to drain (rows held mid-pass in
@publishing@, and the terminal @sent@/@dead@ rows, are excluded).
-}
countOutboxBacklog :: (Store :> es) => Eff es Int
countOutboxBacklog =
    runTransaction (Tx.statement () countBacklogStmt)

{- | Delete @sent@ rows whose @published_at@ is older than @keepFor@ before
@now@.

Returns the number of rows deleted. @dead@ rows are never deleted: they are
operator action items proving an event was not published. The retention window
only bounds how long successful publish history remains queryable; consumer
dedupe lives in the inbox, not here.
-}
garbageCollectSent ::
    (Store :> es) =>
    NominalDiffTime ->
    UTCTime ->
    Eff es Int
garbageCollectSent keepFor now = do
    let cutoff = addUTCTime (negate keepFor) now
    result <-
        runTransaction $
            Tx.statement cutoff gcSentStmt
    pure (fromIntegral result)

{- | Claim up to @limit@ rows ready for publish.

Rows in @pending@ or @failed@ status whose @next_attempt_at@ has passed
become candidates. The selection is filtered by 'OrderingPolicy':

* 'PerKeyHeadOfLine' — a row is skipped if a row with the same
  @(source, message_key)@ and an earlier @created_at@ is non-terminal.
  Rows with @message_key IS NULL@ bypass the check.
* 'PerSourceStream' — a row is skipped if any earlier row in the same
  @source@ is non-terminal, regardless of key.
* 'StopTheLine' — same as 'PerKeyHeadOfLine' at claim time; the worker
  halts on the first failure (decided at the worker level).
* 'BestEffort' — no head-of-line predicate.

Claimed rows are transitioned to @publishing@ and have their
@attempt_count@ incremented atomically.
-}
claimOutboxBatch ::
    (Store :> es) =>
    OrderingPolicy ->
    Int ->
    UTCTime ->
    Eff es [OutboxRow]
claimOutboxBatch policy limit now =
    runTransaction $
        Tx.statement (fromIntegral limit, now) (claimStmt policy)

{- | Reclaim rows stranded in @publishing@ longer than @olderThan@.

Rows whose claim already consumed the attempt budget are dead-lettered; the
rest return to @failed@ so the regular claim query can retry them. Returns
@(requeued, deadLettered)@.
-}
requeueStuckOutbox ::
    (Store :> es) =>
    Int ->
    NominalDiffTime ->
    UTCTime ->
    Eff es (Int, Int)
requeueStuckOutbox maxAttempts olderThan now =
    runTransaction $ do
        let cutoff = addUTCTime (negate olderThan) now
        dead <- Tx.statement (cutoff, fromIntegral maxAttempts, now) deadLetterStuckStmt
        requeued <- Tx.statement (cutoff, fromIntegral maxAttempts, now) requeueStuckStmt
        pure (fromIntegral requeued, fromIntegral dead)

{- | Mark a row as successfully published. Sets @published_at@ and clears
@last_error@. Returns 'False' if the row left @publishing@ before the mark,
for example because a stale-row sweeper or operator changed it while the
transport publish was in flight. The publish may still have happened; callers
must treat this as at-least-once delivery.
-}
markOutboxSent :: (Store :> es) => OutboxId -> UTCTime -> Eff es Bool
markOutboxSent outboxId now =
    runTransaction $
        Tx.statement (unOutboxId outboxId, now) markSentStmt

{- | Mark a row as failed and decide whether it is retryable or dead.

Reads the current @attempt_count@; if it is greater than or equal to
@maxAttempts@, transitions to 'OutboxDead'. Otherwise transitions to
'OutboxFailed' and sets @next_attempt_at = now + delay@. Returns the
resulting status so the worker can update its summary counters.

Runs inside the caller's transaction to keep "read attempt count → write
status" atomic with respect to other workers.
-}
markOutboxFailedTx ::
    OutboxId ->
    Text ->
    Int ->
    NominalDiffTime ->
    UTCTime ->
    Tx.Transaction OutboxStatus
markOutboxFailedTx outboxId errMsg maxAttempts delay now = do
    currentAttempt <- Tx.statement (unOutboxId outboxId) readAttemptCountStmt
    let attempt = fromMaybe 0 currentAttempt
        shouldDie = attempt >= maxAttempts
        nextStatus = if shouldDie then OutboxDead else OutboxFailed
        nextAttempt = addUTCTime delay now
    Tx.statement
        (unOutboxId outboxId, statusText nextStatus, errMsg, nextAttempt, now)
        markFailedStmt
    pure nextStatus

-- ---------------------------------------------------------------------------
-- Encoder support
-- ---------------------------------------------------------------------------

{- | Flattened row used as the encoder input. Field order is locked to
the INSERT statement; the encoder threads each field through a separate
'E.Params' fragment joined by 'mconcat'.
-}
data EncodedRow = EncodedRow
    { outboxId :: !UUID
    , messageId :: !Text
    , source :: !Text
    , destination :: !Text
    , messageKey :: !(Maybe Text)
    , eventType :: !Text
    , schemaVersion :: !Int64
    , contentType :: !Text
    , schemaRegistry :: !(Maybe Text)
    , schemaSubject :: !(Maybe Text)
    , schemaVersionRef :: !(Maybe Int64)
    , schemaId :: !(Maybe Int64)
    , schemaFingerprint :: !(Maybe Text)
    , sourceEventId :: !(Maybe UUID)
    , sourceGlobalPosition :: !(Maybe Int64)
    , causationId :: !(Maybe UUID)
    , correlationId :: !(Maybe UUID)
    , traceparent :: !(Maybe Text)
    , tracestate :: !(Maybe Text)
    , payloadBytes :: !ByteString
    , attributes :: !(Maybe Value)
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic)

toEncodedRow :: OutboxMessage -> EncodedRow
toEncodedRow message =
    let event = message ^. #event
        mref = event ^. #schemaReference
        mtrace = event ^. #traceContext
     in EncodedRow
            { outboxId = unOutboxId (message ^. #outboxId)
            , messageId = event ^. #messageId
            , source = event ^. #source
            , destination = event ^. #destination
            , messageKey = event ^. #key
            , eventType = event ^. #eventType
            , schemaVersion = fromIntegral (event ^. #schemaVersion)
            , contentType = contentTypeText (event ^. #contentType)
            , schemaRegistry = mref >>= (^. #registry)
            , schemaSubject = mref >>= (^. #subject)
            , schemaVersionRef = fmap fromIntegral (mref >>= (^. #version))
            , schemaId = mref >>= (^. #schemaId)
            , schemaFingerprint = mref >>= (^. #fingerprint)
            , sourceEventId = fmap unEventId (event ^. #sourceEventId)
            , sourceGlobalPosition = fmap unGlobalPosition (event ^. #sourceGlobalPosition)
            , causationId = fmap unEventId (event ^. #causationId)
            , correlationId = fmap unEventId (event ^. #correlationId)
            , traceparent = fmap (^. #traceparent) mtrace
            , tracestate = mtrace >>= (^. #tracestate)
            , payloadBytes = event ^. #payloadBytes
            , attributes = event ^. #attributes
            , occurredAt = event ^. #occurredAt
            }

unEventId :: EventId -> UUID
unEventId (EventId u) = u

unGlobalPosition :: GlobalPosition -> Int64
unGlobalPosition (GlobalPosition i) = i

encodedRowEncoder :: E.Params EncodedRow
encodedRowEncoder =
    mconcat
        [ view #outboxId >$< E.param (E.nonNullable E.uuid)
        , view #messageId >$< E.param (E.nonNullable E.text)
        , view #source >$< E.param (E.nonNullable E.text)
        , view #destination >$< E.param (E.nonNullable E.text)
        , view #messageKey >$< E.param (E.nullable E.text)
        , view #eventType >$< E.param (E.nonNullable E.text)
        , view #schemaVersion >$< E.param (E.nonNullable E.int8)
        , view #contentType >$< E.param (E.nonNullable E.text)
        , view #schemaRegistry >$< E.param (E.nullable E.text)
        , view #schemaSubject >$< E.param (E.nullable E.text)
        , view #schemaVersionRef >$< E.param (E.nullable E.int8)
        , view #schemaId >$< E.param (E.nullable E.int8)
        , view #schemaFingerprint >$< E.param (E.nullable E.text)
        , view #sourceEventId >$< E.param (E.nullable E.uuid)
        , view #sourceGlobalPosition >$< E.param (E.nullable E.int8)
        , view #causationId >$< E.param (E.nullable E.uuid)
        , view #correlationId >$< E.param (E.nullable E.uuid)
        , view #traceparent >$< E.param (E.nullable E.text)
        , view #tracestate >$< E.param (E.nullable E.text)
        , view #payloadBytes >$< E.param (E.nonNullable E.bytea)
        , view #attributes >$< E.param (E.nullable E.jsonb)
        , view #occurredAt >$< E.param (E.nonNullable E.timestamptz)
        ]

-- ---------------------------------------------------------------------------
-- Statements
-- ---------------------------------------------------------------------------

enqueueOutboxStmt :: Statement EncodedRow ()
enqueueOutboxStmt =
    preparable
        """
        INSERT INTO keiro_outbox
          ( outbox_id
          , message_id
          , source
          , destination
          , message_key
          , event_type
          , schema_version
          , content_type
          , schema_registry
          , schema_subject
          , schema_version_ref
          , schema_id
          , schema_fingerprint
          , source_event_id
          , source_global_position
          , causation_id
          , correlation_id
          , traceparent
          , tracestate
          , payload_bytes
          , attributes
          , occurred_at
          )
        VALUES
          ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22)
        ON CONFLICT (source, message_id) DO NOTHING
        """
        encodedRowEncoder
        D.noResult

claimStmt :: OrderingPolicy -> Statement (Int64, UTCTime) [OutboxRow]
claimStmt policy =
    preparable
        (claimSql (policyPredicate policy))
        ( contrazip2
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.timestamptz))
        )
        (D.rowList claimResultDecoder)

policyPredicate :: OrderingPolicy -> Text
policyPredicate = \case
    PerKeyHeadOfLine -> perKeyPredicate
    PerSourceStream -> perSourcePredicate
    StopTheLine -> perKeyPredicate
    BestEffort -> "TRUE"

perKeyPredicate :: Text
perKeyPredicate =
    """
    ( r.message_key IS NULL OR NOT EXISTS (
        SELECT 1 FROM keiro_outbox earlier
        WHERE earlier.source = r.source
          AND earlier.message_key = r.message_key
          AND (earlier.created_at, earlier.outbox_id) < (r.created_at, r.outbox_id)
          AND earlier.status NOT IN ('sent', 'dead') ) )
    """

perSourcePredicate :: Text
perSourcePredicate =
    """
    NOT EXISTS ( SELECT 1 FROM keiro_outbox earlier
      WHERE earlier.source = r.source
        AND (earlier.created_at, earlier.outbox_id) < (r.created_at, r.outbox_id)
        AND earlier.status NOT IN ('sent', 'dead') )
    """

claimSql :: Text -> Text
claimSql predicate =
    """
    WITH ready AS (
      SELECT r.outbox_id, r.created_at AS claim_created_at
      FROM keiro_outbox r
      WHERE r.status IN ('pending', 'failed')
        AND r.next_attempt_at <= $2
        AND (
    """
        <> predicate
        <> """

           )
             ORDER BY r.created_at, r.outbox_id
             LIMIT $1
             FOR UPDATE SKIP LOCKED
           ),
           updated AS (
           UPDATE keiro_outbox kt
           SET status = 'publishing', attempt_count = kt.attempt_count + 1, updated_at = $2
           FROM ready
           WHERE kt.outbox_id = ready.outbox_id
           RETURNING ready.claim_created_at,

           """
        <> rowColumns
        <> """

           )
           SELECT

           """
        <> unqualifiedRowColumns
        <> """

           FROM updated
           ORDER BY claim_created_at, outbox_id
           """

rowColumns :: Text
rowColumns =
    """
    kt.outbox_id, kt.message_id, kt.source, kt.destination, kt.message_key,
    kt.event_type, kt.schema_version, kt.content_type, kt.schema_registry,
    kt.schema_subject, kt.schema_version_ref, kt.schema_id, kt.schema_fingerprint,
    kt.source_event_id, kt.source_global_position, kt.causation_id,
    kt.correlation_id, kt.traceparent, kt.tracestate, kt.payload_bytes,
    kt.attributes, kt.occurred_at, kt.status, kt.attempt_count,
    kt.next_attempt_at, kt.last_error, kt.published_at, kt.created_at,
    kt.updated_at
    """

unqualifiedRowColumns :: Text
unqualifiedRowColumns =
    """
    outbox_id, message_id, source, destination, message_key,
    event_type, schema_version, content_type, schema_registry,
    schema_subject, schema_version_ref, schema_id, schema_fingerprint,
    source_event_id, source_global_position, causation_id,
    correlation_id, traceparent, tracestate, payload_bytes,
    attributes, occurred_at, status, attempt_count,
    next_attempt_at, last_error, published_at, created_at,
    updated_at
    """

claimResultDecoder :: D.Row OutboxRow
claimResultDecoder = outboxRowDecoder

countBacklogStmt :: Statement () Int
countBacklogStmt =
    preparable
        "SELECT COUNT(*)::bigint FROM keiro_outbox WHERE status IN ('pending', 'failed')"
        E.noParams
        (fmap fromIntegral (D.singleRow (D.column (D.nonNullable D.int8))))

gcSentStmt :: Statement UTCTime Int64
gcSentStmt =
    preparable
        """
        WITH deleted AS (
          DELETE FROM keiro_outbox
          WHERE status = 'sent' AND published_at < $1
          RETURNING 1
        )
        SELECT COALESCE(COUNT(*), 0)::bigint FROM deleted
        """
        (E.param (E.nonNullable E.timestamptz))
        (D.singleRow (D.column (D.nonNullable D.int8)))

readAttemptCountStmt :: Statement UUID (Maybe Int)
readAttemptCountStmt =
    preparable
        "SELECT attempt_count FROM keiro_outbox WHERE outbox_id = $1"
        (E.param (E.nonNullable E.uuid))
        (D.rowMaybe (fromIntegral <$> D.column (D.nonNullable D.int8)))

deadLetterStuckStmt :: Statement (UTCTime, Int64, UTCTime) Int64
deadLetterStuckStmt =
    preparable
        """
        UPDATE keiro_outbox
        SET status = 'dead',
            last_error = COALESCE(last_error, 'reclaimed: publisher crashed mid-publish'),
            updated_at = $3
        WHERE status = 'publishing'
          AND updated_at <= $1
          AND attempt_count >= $2
        """
        ( contrazip3
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.timestamptz))
        )
        D.rowsAffected

requeueStuckStmt :: Statement (UTCTime, Int64, UTCTime) Int64
requeueStuckStmt =
    preparable
        """
        UPDATE keiro_outbox
        SET status = 'failed',
            updated_at = $3
        WHERE status = 'publishing'
          AND updated_at <= $1
          AND attempt_count < $2
        """
        ( contrazip3
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.timestamptz))
        )
        D.rowsAffected

markSentStmt :: Statement (UUID, UTCTime) Bool
markSentStmt =
    preparable
        """
        UPDATE keiro_outbox
        SET status = 'sent',
            published_at = $2,
            last_error = NULL,
            updated_at = $2
        WHERE outbox_id = $1
          AND status = 'publishing'
        """
        ( contrazip2
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.timestamptz))
        )
        ((> 0) <$> D.rowsAffected)

markFailedStmt :: Statement (UUID, Text, Text, UTCTime, UTCTime) ()
markFailedStmt =
    preparable
        """
        UPDATE keiro_outbox
        SET status = $2,
            last_error = $3,
            next_attempt_at = $4,
            updated_at = $5
        WHERE outbox_id = $1
        """
        ( contrazip5
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.timestamptz))
        )
        D.noResult

lookupOutboxStmt :: Statement UUID (Maybe OutboxRow)
lookupOutboxStmt =
    preparable
        (selectAllSql <> " WHERE outbox_id = $1")
        (E.param (E.nonNullable E.uuid))
        (D.rowMaybe outboxRowDecoder)

listOutboxStmt :: Statement Text [OutboxRow]
listOutboxStmt =
    preparable
        (selectAllSql <> " WHERE source = $1 ORDER BY created_at, outbox_id")
        (E.param (E.nonNullable E.text))
        (D.rowList outboxRowDecoder)

selectAllSql :: Text
selectAllSql =
    """
    SELECT outbox_id, message_id, source, destination, message_key, event_type,
           schema_version, content_type, schema_registry, schema_subject,
           schema_version_ref, schema_id, schema_fingerprint, source_event_id,
           source_global_position, causation_id, correlation_id, traceparent,
           tracestate, payload_bytes, attributes, occurred_at, status,
           attempt_count, next_attempt_at, last_error, published_at, created_at,
           updated_at
    FROM keiro_outbox
    """

outboxRowDecoder :: D.Row OutboxRow
outboxRowDecoder = fmap assembleRow rawRowDecoder

data RawRow = RawRow
    { outboxId :: !OutboxId
    , messageId :: !Text
    , source :: !Text
    , destination :: !Text
    , key :: !(Maybe Text)
    , eventType :: !Text
    , schemaVersion :: !Int
    , contentType :: !Text
    , schemaRegistry :: !(Maybe Text)
    , schemaSubject :: !(Maybe Text)
    , schemaVersionRef :: !(Maybe Int)
    , schemaId :: !(Maybe Int64)
    , schemaFingerprint :: !(Maybe Text)
    , sourceEventId :: !(Maybe EventId)
    , sourceGlobalPosition :: !(Maybe GlobalPosition)
    , causationId :: !(Maybe EventId)
    , correlationId :: !(Maybe EventId)
    , traceparent :: !(Maybe Text)
    , tracestate :: !(Maybe Text)
    , payloadBytes :: !ByteString
    , attributes :: !(Maybe Value)
    , occurredAt :: !UTCTime
    , status :: !OutboxStatus
    , attemptCount :: !Int
    , nextAttemptAt :: !UTCTime
    , lastError :: !(Maybe Text)
    , publishedAt :: !(Maybe UTCTime)
    , createdAt :: !UTCTime
    , updatedAt :: !UTCTime
    }
    deriving stock (Generic)

rawRowDecoder :: D.Row RawRow
rawRowDecoder =
    RawRow
        <$> (OutboxId <$> D.column (D.nonNullable D.uuid))
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> (fromIntegral <$> D.column (D.nonNullable D.int8))
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nullable D.text)
        <*> D.column (D.nullable D.text)
        <*> (fmap fromIntegral <$> D.column (D.nullable D.int8))
        <*> D.column (D.nullable D.int8)
        <*> D.column (D.nullable D.text)
        <*> (fmap EventId <$> D.column (D.nullable D.uuid))
        <*> (fmap GlobalPosition <$> D.column (D.nullable D.int8))
        <*> (fmap EventId <$> D.column (D.nullable D.uuid))
        <*> (fmap EventId <$> D.column (D.nullable D.uuid))
        <*> D.column (D.nullable D.text)
        <*> D.column (D.nullable D.text)
        <*> D.column (D.nonNullable D.bytea)
        <*> D.column (D.nullable D.jsonb)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nonNullable (D.refine parseStatus D.text))
        <*> (fromIntegral <$> D.column (D.nonNullable D.int8))
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nullable D.text)
        <*> D.column (D.nullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)

assembleRow :: RawRow -> OutboxRow
assembleRow raw =
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
        event =
            IntegrationEvent
                { messageId = raw ^. #messageId
                , source = raw ^. #source
                , destination = raw ^. #destination
                , key = raw ^. #key
                , eventType = raw ^. #eventType
                , schemaVersion = raw ^. #schemaVersion
                , contentType = parseContentType (raw ^. #contentType)
                , schemaReference
                , sourceEventId = raw ^. #sourceEventId
                , sourceGlobalPosition = raw ^. #sourceGlobalPosition
                , payloadBytes = raw ^. #payloadBytes
                , occurredAt = raw ^. #occurredAt
                , causationId = raw ^. #causationId
                , correlationId = raw ^. #correlationId
                , traceContext
                , attributes = raw ^. #attributes
                }
     in OutboxRow
            { outboxId = raw ^. #outboxId
            , event
            , status = raw ^. #status
            , attemptCount = raw ^. #attemptCount
            , nextAttemptAt = raw ^. #nextAttemptAt
            , lastError = raw ^. #lastError
            , publishedAt = raw ^. #publishedAt
            , createdAt = raw ^. #createdAt
            , updatedAt = raw ^. #updatedAt
            }
